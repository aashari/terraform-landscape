require 'stringio'

module TerraformLandscape
  # Takes output from Terraform executable and outputs it in a prettified
  # format.
  class Printer
    def initialize(output)
      @output = output
    end

    def process_stream(io, options = {}) # rubocop:disable Metrics/MethodLength
      apply = nil
      buffer = StringIO.new
      original_tf_output = StringIO.new
      begin
        block_size = 1024

        done = false
        until done
          readable_fds, = IO.select([io])
          next unless readable_fds

          readable_fds.each do |f|
            begin
              new_output = f.read_nonblock(block_size)
              original_tf_output << new_output
              buffer << strip_ansi(new_output)
            rescue IO::WaitReadable # rubocop:disable Lint/HandleExceptions
              # Ignore; we'll call IO.select again
            rescue EOFError
              done = true
            end
          end

          apply = apply_prompt(buffer.string.encode('UTF-8',
                                                    invalid: :replace,
                                                    replace: ''))
          done = true if apply
        end

        begin
          process_string(buffer.string)
          @output.print apply if apply
        rescue ParseError, TerraformPlan::ParseError => e
          raise e if options[:trace]

          @output.warning FALLBACK_MESSAGE
          @output.print original_tf_output.string
        end

        @output.write_from(io)
      ensure
        io.close
      end
    end

    def process_string(plan_output) # rubocop:disable Metrics/MethodLength
      scrubbed_output = strip_ansi(plan_output)

      # Our grammar assumes output with Unix line endings
      scrubbed_output.gsub!("\r\n", "\n")

      # Remove initialization messages like
      # "- Downloading plugin for provider "aws" (1.1.0)..."
      # "- module.base_network"
      # as these break the parser which thinks "-" is a resource deletion
      scrubbed_output.gsub!(/^- .*\.\.\.$/, '')
      scrubbed_output.gsub!(/^- module\..*$/, '')

      # Remove separation lines that appear after refreshing state
      scrubbed_output.gsub!(/^-+$/, '')

      if (matches = scrubbed_output.scan(/^Warning:.*$/))
        matches.each do |warning|
          @output.puts warning.colorize(:yellow)
        end
      end

      # Check if this is modern Terraform output (1.0+)
      is_modern = scrubbed_output =~ /^Terraform will perform the following actions:/ && 
                  (scrubbed_output =~ /^\s*#\s*\S+.*(will|must) be/ || scrubbed_output =~ /^\s*[\+\-~]\/?\+?\s+resource\s+"/)
      
      if is_modern
        # Process modern Terraform format inline
        lines = scrubbed_output.split("\n")
        current_resource = nil
        in_resource = false
        
        lines.each do |line|
          # Skip empty lines and headers
          next if line.strip.empty?
          next if line =~ /^Terraform will perform/
          next if line =~ /^Resource actions are indicated/
          
          # Resource header: # module.foo.aws_instance.bar will be created
          if line =~ /^\s*#\s+(.+?)\s+(will be|must be)\s+(.+)$/
            resource_path = $1
            verb = $2
            action = $3
            
            # Map actions to symbols
            action_symbol = case action
            when 'created' then '+'
            when 'destroyed' then '-'
            when 'updated in-place' then '~'
            when 'replaced' then '-/+'
            else action
            end
            
            # Extract resource type and name
            parts = resource_path.split('.')
            if parts.size >= 2
              resource_type = parts[-2]
              resource_name = parts[-1]
              full_name = parts.size > 2 ? parts[0..-3].join('.') + '.' + resource_name : resource_name
            else
              resource_type = 'unknown'
              resource_name = resource_path
              full_name = resource_name
            end
            
            # Output resource header
            @output.puts format_resource_header(action_symbol, resource_type, full_name)
            in_resource = true
            current_resource = resource_path
            
          # Resource type line: ~ resource "aws_instance" "example" {
          elsif line =~ /^\s*(~|\+|-|[\-\+]\/[\-\+])\s+resource\s+"([^"]+)"\s+"([^"]+)"\s+{/
            change = $1
            resource_type = $2
            resource_name = $3
            
            # For replacements without header, output the resource header
            if change == '-/+' && !current_resource
              @output.puts format_resource_header(change, resource_type, resource_name)
              in_resource = true
            end
            
          # Handle comments about hidden attributes/blocks
          elsif in_resource && line =~ /^\s*#\s*\((\d+)\s+unchanged\s+(attributes?|blocks?)\s+hidden\)/
            # Skip these lines
            
          # Attribute changes inside resource block
          elsif in_resource && line =~ /^\s*(~|\+|-)\s+(\S+)\s*=\s*(.*)$/
            change = $1
            attr = $2
            value = $3
            
            # Handle different change types
            case change
            when '~'
              # Changed attribute - look for => on this or next line
              if value =~ /^(.*?)\s*(?:->|=>\s*)\s*(.*)$/
                old_val = $1.strip
                new_val = $2.strip
                @output.puts format_attribute(attr, "#{old_val} => #{new_val}", change)
              else
                @output.puts format_attribute(attr, value, change)
              end
            when '+'
              @output.puts format_attribute(attr, "=> #{value}", change)
            when '-'
              @output.puts format_attribute(attr, "#{value} =>", change)
            end
            
          # Unchanged attributes
          elsif in_resource && line =~ /^\s+(\S+)\s*=\s*(.*)$/
            attr = $1
            value = $2
            @output.puts format_attribute(attr, value)
            
          # End of resource block
          elsif line =~ /^\s*}/
            in_resource = false
            current_resource = nil
            @output.puts ""
            
          # Plan summary
          elsif line =~ /^Plan:/
            @output.puts "\n#{line.colorize(:cyan)}"
          end
        end
        return
      end

      # Remove preface
      if (match = scrubbed_output.match(/^Path:[^\n]+/))
        scrubbed_output = scrubbed_output[match.end(0)..-1]
      elsif (match = scrubbed_output.match(/^Terraform.+following\sactions:/))
        scrubbed_output = scrubbed_output[match.end(0)..-1]
      elsif (match = scrubbed_output.match(/^\s*(~|\+|\-)/))
        scrubbed_output = scrubbed_output[match.begin(0)..-1]
      elsif scrubbed_output =~ /^(No changes\.|This plan does nothing)/
        @output.puts 'No changes.'
        return
      else
        raise ParseError, 'Output does not contain proper preface'
      end

      # Remove postface
      if (match = scrubbed_output.match(/^Plan:[^\n]+/))
        plan_summary = scrubbed_output[match.begin(0)..match.end(0)]
        scrubbed_output = scrubbed_output[0...match.begin(0)]
      end

      plan = TerraformPlan.from_output(scrubbed_output)
      plan.display(@output)
      @output.puts plan_summary
    end

    private

    def strip_ansi(string)
      string.gsub(/\e\[\d+m/, '')
    end


    def format_resource_header(change, type, name)
      color = case change
      when '+' then :green
      when '-' then :red
      when '~' then :yellow
      when '-/+' then :red
      else :white
      end
      
      "#{change.colorize(color)} #{type}.#{name}".colorize(color)
    end

    def format_attribute(name, value, change = nil)
      # Indent attributes
      line = "    #{name.colorize(:light_black)}: "
      
      if change
        color = case change
        when '+' then :green
        when '-' then :red
        when '~' then :yellow
        else :white
        end
        
        # Handle => for changes
        if value.include?('=>')
          parts = value.split('=>', 2)
          old_val = parts[0].strip
          new_val = parts[1].strip
          
          formatted_value = if old_val.empty?
            "#{new_val}".colorize(:green)
          elsif new_val.empty?
            "#{old_val}".colorize(:red)
          else
            "#{old_val.colorize(:red)}#{' => '.colorize(:light_black)}#{new_val.colorize(:green)}"
          end
          
          line += formatted_value
        else
          line += value.colorize(color)
        end
      else
        line += value
      end
      
      line
    end

    def apply_prompt(output)
      return unless output =~ /Enter a value:\s+$/
      output[/Do you want to perform these actions.*$/m, 0]
    end
  end
end
