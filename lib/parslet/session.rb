module Parslet
  # An incremental parse session. Start with a complete parse, then submit
  # edits using coordinates from the old text. Successful edits return a
  # Session::Result containing the new parse result, the half-open character
  # range that was reparsed and cache-hit evidence.
  class Session
    Result = Struct.new(
      :result,
      :text,
      :range,
      :reparsed_range,
      :cache_hits,
      :cache_misses,
      :hit_offsets,
      keyword_init: true
    )

    attr_reader :text
    attr_reader :result
    attr_reader :cache_hits
    attr_reader :cache_misses
    attr_reader :hit_offsets

    def initialize(parser, text, options={})
      @parser = parser
      @options = options
      @text = text.to_str.dup
      @entries = []
      @cache_hits = 0
      @cache_misses = 0
      @hit_offsets = []
      @result = nil

      parse!(@text, nil)
    end

    def insert(offset, text)
      replace(offset, offset, text)
    end

    def delete(start, ending)
      replace(start, ending, '')
    end

    def replace(start, ending, text)
      replacement = text.to_str
      validate_char_span(@text, start, ending)

      changed = @text[0...start] + replacement + @text[ending..]
      edit = {
        start: start,
        ending: ending,
        replacement: replacement
      }
      parse!(changed, edit)
    end

    def submit(operation)
      type = operation.fetch(:type) { operation.fetch(:operation) }
      start = operation[:start] || operation[:offset] || operation[:at]
      ending = operation[:ending] || operation[:end]
      text = operation[:text] || operation[:replacement] || ''

      case type.to_sym
      when :insert then insert(start, text)
      when :delete then delete(start, ending)
      when :replace then replace(start, ending, text)
      else raise ArgumentError, "unknown edit type: #{type.inspect}"
      end
    end
    alias edit submit

    private

    def parse!(source_text, edit)
      context = Parslet::Atoms::Context.new(Parslet::ErrorReporter::Tree.new)
      if edit
        old_start = char_to_byte(@text, edit[:start])
        old_ending = char_to_byte(@text, edit[:ending])
        offset = edit[:replacement].bytesize - (old_ending - old_start)
        source_for_mapping = Parslet::Source.new(source_text)
        retained = retain_entries(@entries, old_start, old_ending)
        context.restore_entries(
          retained,
          source_for_mapping,
          old_ending,
          offset
        )
      end

      source = Parslet::Source.new(source_text, context)
      success, raw_result = @parser.apply(
        source,
        context,
        !@options[:prefix]
      )

      unless success
        raw_result.raise
      end

      stats = context.cache_stats
      @entries = context.completed_entries
      @text = source_text
      @result = @parser.flatten(raw_result)
      @cache_hits = stats[:hits]
      @cache_misses = stats[:misses]
      @hit_offsets = stats[:hit_positions].map do |byte_position|
        byte_to_char(source_text, byte_position)
      end
      @range = byte_range_to_chars(
        source_text,
        stats[:reparsed_start],
        stats[:reparsed_end]
      )

      build_result
    end

    def build_result
      Result.new(
        result: @result,
        text: @text,
        range: @range,
        reparsed_range: @range,
        cache_hits: @cache_hits,
        cache_misses: @cache_misses,
        hit_offsets: @hit_offsets
      )
    end

    def retain_entries(entries, old_start, old_ending)
      valid = {}
      entries.each do |entry|
        valid[entry] = valid_entry?(entry, old_start, old_ending)
      end

      changed = true
      while changed
        changed = false
        valid.each do |entry, is_valid|
          next unless is_valid
          next if (entry.dependencies || []).all? { |dependency| valid[dependency] }

          valid[entry] = false
          changed = true
        end
      end

      valid.select { |_, is_valid| is_valid }.keys
    end

    def valid_entry?(entry, old_start, old_ending)
      return false if entry.eof && old_ending == @text.bytesize

      entry.read_end < old_start || entry.start >= old_ending
    end

    def char_to_byte(text, char_position)
      text[0, char_position].bytesize
    end

    def byte_to_char(text, byte_position)
      text.byteslice(0, byte_position).size
    end

    def byte_range_to_chars(text, start_byte, end_byte)
      return nil unless start_byte && end_byte

      end_byte = [end_byte, text.bytesize].min
      [byte_to_char(text, start_byte), byte_to_char(text, end_byte)]
    end

    def validate_char_span(text, start, ending)
      unless start >= 0 && start <= text.size
        raise ArgumentError, 'invalid edit start'
      end
      unless ending >= start && ending <= text.size
        raise ArgumentError, 'invalid edit ending'
      end
    end
  end
end
