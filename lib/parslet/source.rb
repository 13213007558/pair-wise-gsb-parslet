
require 'stringio'
require 'strscan'

require 'parslet/position'
require 'parslet/source/line_cache'

module Parslet
  # Wraps the input string for parslet. 
  #
  class Source
    def initialize(str)
      raise(
        ArgumentError, 
        "Must construct Source with a string like object."
      ) unless str.respond_to?(:to_str)

      @str = StringScanner.new(str)

      # maps 1 => /./m, 2 => /../m, etc...
      @re_cache = Hash.new { |h,k| 
        h[k] = /(.|$){#{k}}/m }

      @line_cache = LineCache.new
      @line_cache.scan_for_line_endings(0, str)

      # Read tracking (@api private, used by Parslet::Session): 
      # @min_pos / @max_pos delimit the byte range that was physically read
      # since the last #reset_read_tracking call. @read_windows is a stack of
      # frames (one-element arrays used as mutable cells) that accumulate the
      # read range of nested computations.
      reset_read_tracking
      @read_windows = []
    end

    # The string this source was constructed with. 
    #
    def string
      @str.string
    end

    # The line cache used to compute line/column information for slices.
    #
    attr_reader :line_cache

    # Lowest byte offset that was read since #reset_read_tracking (nil if
    # nothing was read). 
    #
    attr_reader :min_pos

    # Highest byte offset (exclusive) that was read since 
    # #reset_read_tracking. May be one past the end of the string to express
    # that a result depends on the input length (see #chars_left). 
    #
    attr_reader :max_pos

    # Resets the physical read range tracked by #min_pos and #max_pos. 
    # @api private
    #
    def reset_read_tracking
      @min_pos = nil
      @max_pos = 0
    end

    # Notes that the byte range [from, to) has been read and may influence
    # the parse result. @api private
    #
    def note_read(from, to)
      @min_pos = from if @min_pos.nil? || from < @min_pos
      @max_pos = to if to > @max_pos
      @read_windows.each do |window|
        window[0] = to if to > window[0]
      end
      nil
    end

    # Like #note_read, but only accounts towards open read windows, not
    # towards the physical read range. Used when a cached result is replayed:
    # the bytes were read earlier, not now. @api private
    #
    def note_cached_read(bytepos)
      @read_windows.each do |window|
        window[0] = bytepos if bytepos > window[0]
      end
      nil
    end

    # Opens a read window at +start+. All reads until the matching
    # #pop_read_window are accumulated and the maximum read offset (exclusive)
    # is returned then. Windows nest. @api private
    #
    def push_read_window(start)
      @read_windows.push([start])
      nil
    end

    # Closes the innermost read window and returns the highest byte offset
    # (exclusive) that was read while it was open. @api private
    #
    def pop_read_window
      @read_windows.pop[0]
    end
  
    # Checks if the given pattern matches at the current input position. 
    #
    # @param pattern [Regexp] pattern to check for
    # @param length [Integer] minimum number of characters the pattern
    #   needs to match (optional); used to detect that a failure depends on
    #   the end of input
    # @return [Boolean] true if the pattern matches at #pos
    #
    def matches?(pattern, length=nil)
      len = @str.match?(pattern)

      if len
        # match? returns the length of the match in bytes. 
        note_read(@str.pos, @str.pos + len)
      elsif @str.rest_size == 0
        # Matching at the end of input: the failure depends on the input
        # length. 
        note_read(@str.pos, @str.string.bytesize + 1)
      elsif length && @str.rest_size < length
        # The input ends before the pattern could match completely; the
        # failure depends on the input length. 
        note_read(@str.pos, @str.string.bytesize + 1)
      else
        # A failed anchored match has examined at least the character at the
        # current position. Callers that probe further (like Str) account for
        # their additional reads through #consume / #chars_left. 
        note_read(@str.pos, @str.pos + @str.peek(1).bytesize)
      end

      len
    end
    alias match matches?
    
    # Consumes n characters from the input, returning them as a slice of the
    # input. 
    #
    def consume(n)
      position = self.pos
      slice_str = @str.scan(@re_cache[n])
      note_read(position.bytepos, @str.pos)
      slice = Parslet::Slice.new(
        position, 
        slice_str,
        @line_cache)

      return slice
    end
    
    # Returns how many chars remain in the input. 
    #
    def chars_left
      # Only at the end of input does the answer depend on the input
      # length; otherwise the character at the current position (already
      # accounted for by the match attempt that leads here) proves that
      # input remains. 
      note_read(@str.pos, @str.string.bytesize + 1) if @str.rest_size == 0
      @str.rest_size
    end

    # Returns how many chars there are between current position and the 
    # string given. If the string given doesn't occur in the source, then 
    # the remaining chars (#chars_left) are returned. 
    #
    # @return [Fixnum] count of chars until str or #chars_left
    #
    def chars_until str
      slice_str = @str.check_until(Regexp.new(Regexp.escape(str)))
      if slice_str
        note_read(@str.pos, @str.pos + slice_str.bytesize)
      else
        note_read(@str.pos, @str.string.bytesize + 1)
        return chars_left
      end
      return slice_str.size - str.size
    end
    
    # Position of the parse as a character offset into the original string. 
    #
    # @note Please be aware of encodings at this point. 
    #
    def pos
      Position.new(@str.string, @str.pos)
    end
    def bytepos
      @str.pos
    end

    # @note Please be aware of encodings at this point. 
    #
    def bytepos=(n)
      @str.pos = n
    rescue RangeError
    end

    # Returns a <line, column> tuple for the given position. If no position is
    # given, line/column information is returned for the current position
    # given by #pos. 
    #
    def line_and_column(position=nil)
      @line_cache.line_and_column(position || self.bytepos)
    end
  end
end
