module Parslet
  # A parsing session: parses a text once, then accepts edits (insertions,
  # deletions and replacements) described in coordinates of the previously
  # parsed text. After each edit, only the parts of the parse that could be
  # affected by the edit are recomputed; everything else is served from the
  # packrat cache of the previous parse. 
  #
  # Cache validity is not based on consumed input alone: the reads performed
  # by failed branches and by lookaheads also influence parse results, so
  # they are tracked as part of each cache entry and invalidate it when an
  # edit touches them. Cache entries whose computation evaluated a dynamic
  # block are never reused across edits. Captures made while parsing are
  # journaled into the cache entries and replayed on cache hits, so dynamic
  # blocks that are re-evaluated see the same captures as in a full parse. 
  #
  # When an edit shifts parts of the input, the positions of all reused
  # results (slices, their offsets and line/column information, and captured
  # values) are remapped to the new text. 
  #
  # Example: 
  #
  #   session = Parslet::Session.new(MyParser.new)
  #   session.parse("aaa,bbb,ccc")
  #
  #   # replace "bbb" with "xxx" (coordinates refer to the text above)
  #   result = session.replace(4, 3, "xxx")
  #   session.reparse_range  # => 4..7: range actually re-parsed
  #   session.cache_hits     # => evidence that unchanged parts were reused
  #
  class Session
    # The text as of the last #parse or edit. 
    attr_reader :text

    # Number of cache hits during the last parse. Positive numbers after an
    # edit prove that unchanged regions were reused instead of re-parsed. 
    attr_reader :cache_hits

    # Number of cache misses during the last parse. 
    attr_reader :cache_misses

    # The range of character offsets (into the current #text) that was
    # actually read again during the last parse. Everything outside this
    # range was served from the cache. nil if nothing had to be re-read. 
    attr_reader :reparse_range

    # @param parser [#parse] a parslet (usually a Parslet::Parser instance);
    #   the same instance is reused for all parses of this session, which is
    #   what makes rule memoization (and hence cache reuse) work. 
    #
    def initialize(parser)
      @parser = parser
    end

    # Parses +text+ from scratch and returns the parse result, just like
    # Parslet::Atoms::Base#parse would. Subsequent edits are described in
    # coordinates of this text. 
    #
    def parse(text)
      @text = text.to_str.dup
      @source = Parslet::Source.new(@text)
      @context = Parslet::Atoms::Context.new(nil)

      run_parse
    end

    # Submits an edit to the text and returns the new parse result. 
    #
    # @param start [Integer] character offset of the edit, in coordinates of
    #   the text as of the last #parse or edit
    # @param delete_count [Integer] number of characters to delete at +start+
    # @param replacement [String] text to insert at +start+
    # @return [Hash, Array, Parslet::Slice] the new parse result tree
    #
    # After the edit, #reparse_range contains the range of the new text that
    # was actually re-parsed, and #cache_hits / #cache_misses describe cache
    # usage. 
    #
    def edit(start, delete_count, replacement)
      fail "Call #parse before submitting edits." unless @context

      replacement = replacement.to_s
      check_edit_bounds(start, delete_count)

      start_byte = byte_offset(@text, start)
      deleted = @text.slice(start, delete_count) || ""
      edit_end_byte = start_byte + deleted.bytesize

      new_text = @text.slice(0...start) + replacement +
        (@text.slice(start + delete_count..-1) || "")
      delta = replacement.bytesize - deleted.bytesize

      new_source = Parslet::Source.new(new_text)
      carried_cache = transform_cache(
        start_byte, edit_end_byte, delta, new_source)

      @text = new_text
      @source = new_source
      @context = Parslet::Atoms::Context.new(nil, carried_cache)

      run_parse
    end

    # Inserts +str+ at character offset +pos+. See #edit. 
    #
    def insert(pos, str)
      edit(pos, 0, str)
    end

    # Deletes +length+ characters starting at character offset +pos+. 
    # See #edit. 
    #
    def delete(pos, length)
      edit(pos, length, "")
    end

    # Replaces +length+ characters starting at character offset +pos+ with
    # +str+. See #edit. 
    #
    def replace(pos, length, str)
      edit(pos, length, str)
    end

  private
    # Runs the parse over the current @source with the current @context and
    # collects statistics. 
    #
    def run_parse
      @context.reset_stats!
      @source.reset_read_tracking

      result = @parser.parse_with_context(@source, @context)

      @cache_hits = @context.hits
      @cache_misses = @context.misses
      @reparse_range = compute_reparse_range

      result
    end

    # The span of the current text that was physically read during the last
    # parse, as a range of character offsets. 
    #
    def compute_reparse_range
      min = @source.min_pos
      return nil unless min

      max = [@source.max_pos, @text.bytesize].min
      min = [min, max].min

      char_offset(@text, min)...char_offset(@text, max)
    end

    # Carries cache entries that cannot be affected by the edit over into a
    # new cache: entries that only read input before the edit are kept,
    # entries that start after the edit are shifted by +delta+. All entries
    # that read part of the edited range - including reads by failed
    # branches and lookaheads - and all entries that evaluated dynamic
    # blocks are dropped. 
    #
    def transform_cache(edit_start_byte, edit_end_byte, delta, new_source)
      carried = Hash.new { |h, k| h[k] = {} }

      @context.each_cache_entry do |pos, object_id, entry|
        next if entry.dynamic

        if entry.read_end <= edit_start_byte
          # Entirely before the edit: unchanged. 
          carried[pos][object_id] = remap_entry(entry, new_source, 0)
        elsif pos >= edit_end_byte
          # Entirely after the edit: same content, shifted position. 
          carried[pos + delta][object_id] = 
            remap_entry(entry, new_source, delta)
        end

        # All other entries read (part of) the edited range and are dropped.
      end

      carried
    end

    # Copies a cache entry, remapping all slices in its result and in its
    # journaled captures to +new_source+, shifted by +delta+ bytes. 
    #
    def remap_entry(entry, new_source, delta)
      Parslet::Atoms::Context::CacheEntry.new(
        remap_value(entry.result, new_source, delta),
        entry.advance,
        entry.read_end + delta,
        remap_value(entry.captures, new_source, delta),
        entry.dynamic)
    end

    # Deeply remaps all slices contained in a cached value. Produces new
    # arrays and hashes, leaving the originals (which the user may hold
    # through a previous parse result) untouched. 
    #
    def remap_value(value, new_source, delta)
      case value
      when Parslet::Slice
        remap_slice(value, new_source, delta)
      when Array
        value.map { |element| remap_value(element, new_source, delta) }
      when Hash
        value.each_with_object({}) do |(key, element), hash|
          hash[key] = remap_value(element, new_source, delta)
        end
      else
        value
      end
    end

    # Returns a slice that points at the same content, but located in
    # +new_source+ at a position shifted by +delta+ bytes. Line and column
    # information is derived from the new source's line cache. 
    #
    def remap_slice(slice, new_source, delta)
      Parslet::Slice.new(
        Parslet::Position.new(
          new_source.string, 
          slice.position.bytepos + delta),
        slice.str,
        new_source.line_cache)
    end

    def check_edit_bounds(start, delete_count)
      unless start.is_a?(Integer) && delete_count.is_a?(Integer) &&
          start >= 0 && delete_count >= 0 &&
          start + delete_count <= @text.length
        fail ArgumentError, 
          "Edit (#{start.inspect}, #{delete_count.inspect}) is outside the " \
          "current text of #{@text.length} characters."
      end
    end

    # Byte offset of the character at +char_index+ in +text+. 
    #
    def byte_offset(text, char_index)
      text.slice(0, char_index).to_s.bytesize
    end

    # Character offset of the character containing +byte_index+ in +text+. 
    #
    def char_offset(text, byte_index)
      text.byteslice(0, byte_index).to_s.length
    end
  end
end

