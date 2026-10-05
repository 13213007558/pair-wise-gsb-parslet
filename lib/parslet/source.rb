require 'stringio'
require 'strscan'

require 'parslet/position'
require 'parslet/source/line_cache'

module Parslet
  class Source
  attr_reader :base_bytepos, :rollback_positions

    def initialize(str, finished: true)
      unless str.respond_to?(:to_str)
        raise ArgumentError, 'Must construct Source with a string like object.'
      end

      input = str.to_str
      @encoding = input.encoding
      @buffer = String.new(encoding: Encoding::BINARY)
      @base_bytepos = 0
      @base_charpos = 0
    @finished = false
    @rollback_positions = []
      @pause_pos = 0
      @on_release = nil
      @input = input

      append_buffer(input)
      @finished = finished
      rebuild_scanner

      @re_cache = Hash.new { |cache, size| cache[size] = /(.|$){#{size}}/m }
      @line_cache = LineCache.new
      @line_cache.scan_for_line_endings(0, @scannable)
    end

    def matches?(pattern)
      @str.match?(pattern)
    end
    alias match matches?

    def consume(char_count)
      position = pos
      consumed = @str.scan(@re_cache[char_count])
      Slice.new(position, consumed, @line_cache)
    end

    def chars_left
      @str.rest_size
    end

    def bytes_left
      @str.rest.bytesize + pending_bytesize
    end

    def bytesize
      @base_bytepos + @buffer.bytesize
    end

    def finished?
      @finished
    end

    def append(chunk)
      raise ArgumentError, 'Cannot append to a finished source.' if @finished

      old_scannable_bytesize = @scannable.bytesize
      append_buffer(chunk)
      rebuild_scanner
      scan_new_line_endings(old_scannable_bytesize)
    end

    def finish
      return if @finished

      old_scannable_bytesize = @scannable.bytesize
      @finished = true
      rebuild_scanner
      scan_new_line_endings(old_scannable_bytesize)
    end

  def with_rollback(position=bytepos)
    @rollback_positions.push(position)
    yield
  ensure
    @rollback_positions.pop
  end

  def wait_at(position, commit)
    @pause_pos = position
    @pause_commit_pos = commit ? bytepos : position
    @resume_commit = commit
    Fiber.yield
  end

  def pause_pos
    @pause_pos
  end

  def pause_commit_pos
    @pause_commit_pos || @pause_pos
  end

  def speculative?
    !@rollback_positions.empty?
  end

  def consume_all_commit?
    @rollback_positions.empty?
  end

  def reset_resume_commit!
    @resume_commit = false
  end

  def wait
    @pause_pos = @rollback_positions.empty? ? bytepos : @rollback_positions.min
    @pause_commit_pos = @pause_pos
    @resume_commit = @rollback_positions.empty?
    Fiber.yield
  end

  def resume_commit?
    @resume_commit
  end

    def possible_string_prefix?(string)
      return false if @finished

      available = @buffer.byteslice(scanner_bytepos, string.bytesize)
      available && string.b.start_with?(available)
    end

    def pending_character?
      return false if @finished

      pending = @buffer.byteslice(scanner_bytepos, 4) or return false
      bytes = pending.bytes
      first = bytes.first or return false
      expected = expected_utf8_size(first)
      return false unless expected

      bytes.size < expected &&
        bytes[1..-1].to_a.all? { |byte| continuation_byte?(byte) }
    end

    def on_release(&block)
      @on_release = block
    end

    def release_before(position)
      return 0 if position <= @base_bytepos

      relative_position = position - @base_bytepos
      released = @scannable.byteslice(0, relative_position)
      scanner_pos = @str.pos

      @buffer = @buffer.byteslice(released.bytesize, @buffer.bytesize) ||
        String.new(encoding: Encoding::BINARY)
      @base_bytepos += released.bytesize
      @base_charpos += released.size
      rebuild_scanner(scanner_pos - released.bytesize)
      @on_release.call(@base_bytepos) if @on_release

      released.bytesize
    end

    def chars_until(str)
      found = @str.check_until(Regexp.new(Regexp.escape(str)))
      return chars_left unless found
      found.size - str.size
    end

    def pos
      char_offset =
        if @input
          @input.byteslice(0, bytepos).size
        else
          @base_charpos + @str.pre_match.to_s.size
        end
      Position.char(char_offset, bytepos)
    end

    def bytepos
      @base_bytepos + @str.pos
    end

    def bytepos=(position)
      @str.pos = position - @base_bytepos
    rescue RangeError
    end

    def line_and_column(position=nil)
      @line_cache.line_and_column(position || bytepos)
    end

  private

    def append_buffer(chunk)
      @buffer << chunk.to_str.b
    end

    def rebuild_scanner(position=0)
      @scannable = scannable_prefix.dup.force_encoding(@encoding)
      @str = StringScanner.new(@scannable)
      @str.pos = [[position, 0].max, @scannable.bytesize].min
    end

    def scannable_prefix
      return @buffer if @finished
      @buffer.byteslice(0, utf8_boundary(@buffer.bytes)) ||
        String.new(encoding: Encoding::BINARY)
    end

    def utf8_boundary(bytes)
      1.upto([4, bytes.size].min) do |size|
        offset = bytes.size - size
        expected = expected_utf8_size(bytes[offset])
        next unless expected

        return offset if expected > size &&
          bytes[(offset + 1)...bytes.size].to_a.all? { |byte| continuation_byte?(byte) }
        return bytes.size if expected <= size
      end

      bytes.size
    end

    def expected_utf8_size(byte)
      if byte.between?(0xC2, 0xDF) then 2
      elsif byte.between?(0xE0, 0xEF) then 3
      elsif byte.between?(0xF0, 0xF4) then 4
      end
    end

    def continuation_byte?(byte)
      byte.between?(0x80, 0xBF)
    end

    def pending_bytesize
      @buffer.bytesize - @str.pos - @str.rest.bytesize
    end

    def scanner_bytepos
      @base_bytepos + @str.pos
    end

    def scan_new_line_endings(old_scannable_bytesize)
      new_part = @scannable.byteslice(old_scannable_bytesize, @scannable.bytesize)
      @line_cache.scan_for_line_endings(
        @base_bytepos + old_scannable_bytesize, new_part)
    end
  end
end
