# Support for indentation-sensitive ("layout") grammars, where the nesting
# of rules is expressed through indentation alone. This module contains the
# non-atom parts of that support:
#
# * Parslet::Layout::Policy - how tab characters in indentation are treated.
#   Configured once per parser, see Parslet::Parser.layout.
# * Parslet::Layout::State  - the stack of indentation levels that is
#   maintained automatically during a parse. Grammar authors never see or
#   touch this; the parse context rolls it back along with failed
#   alternatives and lookaheads.
# * Parslet::Layout.scan_gap - scans the whitespace between two lines of
#   content (blank lines plus the indentation of the next content line).
#
# The atoms that make use of this are Parslet::Atoms::Layout, created through
# Parslet.indent, Parslet.same_indent and Parslet.dedent.
#
module Parslet::Layout
  # Raised when indentation violates the configured layout policy (illegal
  # tab usage) or the structure of the input (unindent that matches no
  # outer level). Carries the byte position of the offending character so
  # that the parse can fail with an accurate line/column indication.
  #
  class Violation < StandardError
    attr_reader :bytepos
    def initialize(message, bytepos)
      super(message)
      @bytepos = bytepos
    end
  end

  # Decides how leading whitespace of a line is measured and which
  # whitespace is considered legal. The policy is configured centrally on
  # the parser:
  #
  #   class MyParser < Parslet::Parser
  #     layout tab: :expand, tab_width: 4
  #   end
  #
  # Supported options:
  #
  # * tab: :forbid (default) - any tab character in indentation is an error.
  # * tab: :expand - tabs advance to the next multiple of :tab_width
  #   (default 8). Mixing tabs and spaces within the indentation of a single
  #   line is an error in this mode, since such lines are ambiguous.
  #
  class Policy
    DEFAULT_TAB_WIDTH = 8

    attr_reader :tab, :tab_width

    def initialize(options={})
      @tab = options.fetch(:tab, :forbid)
      @tab_width = options.fetch(:tab_width, DEFAULT_TAB_WIDTH)

      unless [:forbid, :expand].include?(@tab)
        raise ArgumentError,
          "Unknown tab policy #{@tab.inspect}, expected :forbid or :expand."
      end
    end

    # Builds a policy from anything the user might have supplied: nil (use
    # defaults), an options hash or a ready-made policy instance.
    #
    def self.build(options)
      case options
      when nil    then new
      when self   then options
      when Hash   then new(options)
      else
        raise ArgumentError,
          "Cannot build a layout policy from #{options.inspect}."
      end
    end

    # Measures the indentation +whitespace+ (a string of spaces and tabs)
    # and returns its width in columns. +bytepos+ is the byte offset of the
    # whitespace within the source, used to position policy violations.
    #
    # @raise [Violation] if the whitespace violates the tab policy
    #
    def measure(whitespace, bytepos)
      case tab
      when :forbid
        if index = whitespace.index("\t")
          raise Violation.new(
            "Tab character in indentation, but tab policy is :forbid",
            bytepos + index)
        end
        whitespace.size
      when :expand
        check_unmixed(whitespace, bytepos)

        width = 0
        whitespace.each_char do |char|
          width = char == "\t" ?
            width + (tab_width - width % tab_width) :
            width + 1
        end
        width
      end
    end

  private
    def check_unmixed(whitespace, bytepos)
      tab_index = whitespace.index("\t")
      space_index = whitespace.index(' ')
      return unless tab_index && space_index

      # Point at the character that introduced the mix.
      offender = tab_index < space_index ? space_index : tab_index
      raise Violation.new(
        "Mixed tabs and spaces in indentation",
        bytepos + offender)
    end
  end

  # The indentation level stack maintained during a parse. Starts out with a
  # single base level of 0. Layout atoms push and pop levels; the parse
  # context snapshots and restores this state so that failed alternatives
  # and lookaheads leave no trace.
  #
  class State
    attr_reader :policy

    def initialize(policy)
      @policy = policy
      @levels = [0]
    end

    # The indentation (in columns) that the current level expects.
    #
    def current
      @levels.last
    end

    # True if no level has been pushed beyond the base level.
    #
    def base?
      @levels.size == 1
    end

    def push(level)
      @levels.push(level)
    end

    def pop
      @levels.pop
    end

    # An immutable copy of the current levels. Used both as a transactional
    # mark for rollback and as a fingerprint when caching parse results
    # (results of a layout-aware parse are only valid for the layout state
    # they were produced in).
    #
    def snapshot
      @levels.dup.freeze
    end

    def restore(snapshot)
      @levels = snapshot.dup
    end
  end

  # The result of scanning the whitespace between the current position and
  # the next line of content: any blank lines plus the indentation of that
  # line. Blank lines never establish a level of their own; they are simply
  # part of the gap.
  #
  class Gap
    # The indentation of the next content line (spaces and tabs only).
    attr_reader :whitespace

    # Byte offset of #whitespace within the source.
    attr_reader :whitespace_bytepos

    def initialize(line_start, whitespace, whitespace_bytepos, eof)
      @line_start = line_start
      @whitespace = whitespace
      @whitespace_bytepos = whitespace_bytepos
      @eof = eof
    end

    # True if the next content sits at the start of a line, i.e. the gap
    # contained at least one line break or the scan started at a line
    # boundary.
    def line_start?
      @line_start
    end

    # True if no further content line exists (end of input reached).
    def eof?
      @eof
    end
  end

  # A line that contains only whitespace (and its line ending).
  BLANK_LINE = /[ \t]*\n/

  # The leading whitespace of a content line.
  INDENTATION = /[ \t]*/

  # Scans the gap between the current position and the next content line:
  # consumes blank lines (lines containing only whitespace) and - unless
  # +consume_indentation+ is false - the indentation of the next content
  # line. Returns a Gap describing what was found.
  #
  # When +consume_indentation+ is false, the indentation is measured but
  # left in the input; trailing whitespace at the very end of input is
  # always consumed.
  #
  def self.scan_gap(source, consume_indentation: true)
    line_start = source.at_line_start?

    # Blank lines never establish a new level; skip them all.
    while (size = source.match(BLANK_LINE))
      source.consume(size)
      line_start = true
    end

    whitespace = ''
    whitespace_bytepos = source.bytepos
    eof = source.chars_left == 0

    if !eof && (size = source.match(INDENTATION)) && size > 0
      whitespace = source.consume(size).to_s
      eof = source.chars_left == 0
      source.bytepos = whitespace_bytepos unless consume_indentation || eof
    end

    Gap.new(line_start, whitespace, whitespace_bytepos, eof)
  end
end
