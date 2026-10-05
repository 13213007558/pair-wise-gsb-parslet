require 'strscan'

require 'parslet/position'
require 'parslet/source/line_cache'

module Parslet
  # Raised when a streaming source is asked for information about input
  # that has already been released. Should never happen for grammars that
  # only rewind through parslet's own atoms; custom atoms that rewind the
  # source to arbitrary positions are incompatible with input release.
  #
  class ReleasedInputError < StandardError; end

  # A source of input for incremental (streaming) parses. Input is appended
  # chunk by chunk using #feed; the end of input is signalled explicitly
  # using #finish!.
  #
  # The streaming source implements the same protocol towards parslet atoms
  # that Parslet::Source does (#matches?, #consume, #chars_left, #pos,
  # #bytepos, #bytepos=, #line_and_column), plus a number of streaming
  # specific methods:
  #
  # * #wait_for_input? - suspends the current fiber until more input is
  #   available (or the input is finished), letting atoms block instead of
  #   failing on premature end of input.
  # * #release_before - drops input that the parse will never backtrack to.
  # * #retained_bytes - amount of input currently held in memory.
  #
  # Positions are absolute byte/character offsets into the stream; they
  # stay valid even when old input is released. Bytes that would split a
  # multi-byte character are held back until the character is complete, so
  # atoms never see invalid byte sequences mid-stream.
  #
  class StreamingSource
    # A position inside a StreamingSource. Both the byte and the character
    # offset are captured when the position is created, so positions (and
    # the slices carrying them) remain fully valid even after the
    # corresponding input has been released.
    #
    class Position
      include Comparable

      attr_reader :bytepos

      def initialize(bytepos, charpos)
        @bytepos = bytepos
        @charpos = charpos
      end

      def charpos
        unless @charpos
          raise ReleasedInputError,
            'character offset is no longer known, the input was released'
        end
        @charpos
      end

      def <=>(other)
        bytepos <=> other.bytepos
      end
    end

    # How many bytes to walk back when looking for a truncated multi-byte
    # character at the end of the pending buffer. Covers all common
    # encodings (UTF-8 needs at most 4, UTF-16/32 at most 4).
    TRUNCATION_LOOKBACK = 8

    # How many bytes may be retained beyond the last release point before
    # #consume asks the release handler for a new horizon.
    RELEASE_THRESHOLD = 4096

    attr_reader :encoding

    # Called (roughly every RELEASE_THRESHOLD consumed bytes) to give the
    # owner a chance to release input. Must return the absolute byte
    # position up to which input may be dropped, or nil.
    attr_accessor :release_handler

    def initialize(encoding=Encoding::UTF_8)
      @encoding = encoding

      # Bytes fed but not yet exposed to the parser (truncated character).
      @pending = +''.b

      # Exposed input, always valid in @encoding (except possibly after
      # #finish! exposed genuinely invalid bytes).
      @buffer = +''.force_encoding(encoding)
      @scanner = StringScanner.new(@buffer)

      @base = 0       # absolute byte offset of the first byte of @buffer
      @char_base = 0  # absolute char offset of the first char of @buffer
      @pos = 0        # absolute byte offset of the read head
      @head_chars = 0 # absolute char offset of the read head (if valid)
      @eof = false

      @line_cache = Parslet::Source::LineCache.new
      @re_cache = Hash.new { |h, k| h[k] = /(.|$){#{k}}/m }

      @release_mark = 0
    end

    # Streaming API -------------------------------------------------------

    # Appends a chunk of input. Bytes that form an incomplete trailing
    # character are held back until #feed completes them (or #finish!
    # exposes them as-is).
    #
    def feed(chunk)
      raise 'input is finished, cannot feed more' if @eof

      @pending << chunk.to_s.b
      expose_pending
      self
    end

    # Signals end of input. Any pending bytes (even ones that do not form
    # valid characters) are exposed to the parser.
    #
    def finish!
      return self if @eof

      @eof = true
      expose_pending
      self
    end

    # True once #finish! was called: no more input will ever arrive.
    #
    def eof?
      @eof
    end

    # Called by atoms that cannot decide whether their input matches
    # because not enough input is available. Suspends the current fiber
    # until more input arrives (returns true, the caller should retry) or
    # until it is clear that waiting is pointless (returns false: end of
    # input reached, enough input present to decide, or the available
    # input can never be a prefix of +literal+).
    #
    def wait_for_input?(needed=1, literal=nil)
      waited = false
      loop do
        return false if @eof
        return waited if chars_left >= needed
        return false if literal && !literal.start_with?(remaining)

        waited = true
        Fiber.yield(:waiting)
      end
    end

    # Drops all input before the given absolute byte position. The parse
    # guarantees it will never read from positions before +absolute+
    # again. Positions and slices already handed out stay valid.
    #
    def release_before(absolute)
      return if absolute <= @base
      if absolute > @pos
        raise ReleasedInputError,
          'cannot release input past the read head'
      end

      rel = absolute - @base
      @char_base += @buffer.byteslice(0, rel).size
      @buffer = @buffer.byteslice(rel, @buffer.bytesize - rel)
      @base = absolute
      @scanner = StringScanner.new(@buffer)
      @release_mark = @buffer.bytesize
      nil
    end

    # Number of input bytes currently held in memory (exposed buffer plus
    # pending incomplete character bytes).
    #
    def retained_bytes
      @buffer.bytesize + @pending.bytesize
    end

    # Total number of bytes fed so far.
    #
    def total_bytes
      @base + @buffer.bytesize + @pending.bytesize
    end

    # Source protocol -----------------------------------------------------

    # Checks if the given pattern matches at the current input position.
    #
    def matches?(pattern)
      sync
      @scanner.match?(pattern)
    end
    alias match matches?

    # Consumes n characters from the input, returning them as a slice.
    #
    def consume(n)
      position = pos
      sync
      slice_str = @scanner.scan(@re_cache[n])
      @pos = @base + @scanner.pos
      @head_chars = position.charpos + slice_str.size

      consider_release

      Parslet::Slice.new(position, slice_str, @line_cache)
    end

    # Returns how many characters remain in the exposed input.
    #
    def chars_left
      remaining.size
    end

    # Returns how many chars there are between current position and the
    # string given. If the string does not occur in the exposed input, the
    # remaining chars (#chars_left) are returned.
    #
    def chars_until(str)
      sync
      slice_str = @scanner.check_until(Regexp.new(Regexp.escape(str)))
      return chars_left unless slice_str
      slice_str.size - str.size
    end

    # Position of the parse as an absolute offset into the stream. The
    # character offset is snapshotted eagerly, so positions (and slices
    # carrying them) stay valid after input is released. Positions
    # created below the release horizon (only possible while a failure
    # propagates past already released input) have no character offset.
    #
    def pos
      Position.new(@pos, @pos < @base ? nil : charpos_at(@pos))
    end

    # Absolute byte offset of the read head.
    #
    def bytepos
      @pos
    end

    # Moves the read head to the given absolute byte offset. Moving the
    # head back below released input is allowed as long as no reading
    # happens there (parslet rewinds like this while propagating failure).
    #
    def bytepos=(n)
      @head_chars = nil if n != @pos
      @pos = n
    end

    # Returns a <line, column> tuple for the given position (absolute byte
    # offset or position object). Works for all positions ever fed, even
    # released ones.
    #
    def line_and_column(position=nil)
      position = position.bytepos if position.respond_to?(:bytepos)
      @line_cache.line_and_column(position || @pos)
    end

    # Character offset for an absolute byte offset. Only callable for
    # positions that have not been released; positions handed out via #pos
    # snapshot their character offset eagerly, so this is only called
    # while the position is still retained.
    #
    def charpos_at(bytepos)
      return @head_chars if @head_chars && bytepos == @pos
      if bytepos < @base
        raise ReleasedInputError,
          'input has been released below this position'
      end

      @char_base + @buffer.byteslice(0, bytepos - @base).size
    end

  private

    def sync
      @scanner.pos = @pos - @base
    end

    def remaining
      @buffer.byteslice(@pos - @base, @buffer.bytesize - (@pos - @base))
    end

    # Moves as many pending bytes as possible into the exposed buffer.
    # Unless the input is finished, a trailing incomplete character is
    # kept pending.
    #
    def expose_pending
      return if @pending.empty?

      candidate = @pending.dup.force_encoding(@encoding)
      if @eof || candidate.valid_encoding?
        expose = candidate
        @pending = +''.b
      else
        keep = valid_prefix_bytes(candidate)
        return if keep == 0
        expose = candidate.byteslice(0, keep)
        @pending = @pending.byteslice(keep, @pending.bytesize - keep)
      end

      absolute_start = @base + @buffer.bytesize
      @buffer << expose
      @scanner = StringScanner.new(@buffer)
      scan_line_endings(absolute_start, expose)
    end

    # Length of the longest valid-encoding prefix of str (in bytes). Only
    # looks a few bytes back: longer invalid stretches are genuine input
    # errors, not truncated characters, and stay pending until #finish!.
    #
    def valid_prefix_bytes(str)
      len = str.bytesize
      max = [TRUNCATION_LOOKBACK, len].min
      (0..max).each do |i|
        return len - i if str.byteslice(0, len - i).valid_encoding?
      end
      0
    end

    def scan_line_endings(absolute_start, expose)
      @line_cache.scan_for_line_endings(absolute_start, expose)
    rescue ArgumentError
      # Genuinely invalid bytes (exposed at end of input): line information
      # for the invalid tail is best effort only.
    end

    def consider_release
      return unless @release_handler
      return if @buffer.bytesize - @release_mark < RELEASE_THRESHOLD

      @release_mark = @buffer.bytesize
      horizon = @release_handler.call
      release_before([horizon, @pos].min) if horizon && horizon > @base
    end
  end
end
