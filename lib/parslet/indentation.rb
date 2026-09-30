class Parslet::Indentation; end

require 'parslet/indentation/state'
require 'parslet/indentation/atoms'

class Parslet::Indentation
  DEFAULT_BRACKETS = {
    '(' => ')',
    '[' => ']',
    '{' => '}'
  }.freeze

  TAB_POLICIES = {
    :expand => :expand,
    :expanded => :expand,
    :character => :character,
    :literal => :character,
    :tab => :character,
    :reject => :reject,
    :spaces => :reject,
    :strict => :reject
  }.freeze

  attr_reader :brackets

  def initialize(options={})
    @blank_lines = line_option(options[:blank_lines], :ignore)
    @comment_lines = line_option(options[:comment_lines], options.key?(:comments) || options.key?(:comment) ? :ignore : :normal)
    @comments = build_parser(options[:comments] || options[:comment])
    @tab_width = options.fetch(:tab_width, options.fetch(:tab_size, 8)).to_i
    @tab_policy = tab_policy(options.fetch(:tabs, :expand))
    @brackets = build_brackets(options[:brackets])
  end

  def same
    Level.new(self, :same)
  end
  alias_method :same_level, :same

  def indent
    Level.new(self, :indent)
  end

  def dedent
    Level.new(self, :dedent)
  end
  alias_method :unindent, :dedent

  def eof
    End.new(self)
  end
  alias_method :finish, :eof
  alias_method :end_of_input, :eof

  def open(delimiter=nil)
    delimiter ||= default_bracket_key
    Bracket.new(self, :open, delimiter, brackets.fetch(delimiter))
  end

  def close(delimiter=nil)
    delimiter ||= default_bracket_value
    Bracket.new(self, :close, delimiter)
  end
  alias_method :closing, :close
  alias_method :open_bracket, :open
  alias_method :close_bracket, :close

  def ignoring_indentation(content)
    bracketed(content)
  end

  def bracketed(content, opener=nil, closer=nil)
    open(opener) >> content >> close(closer)
  end

  def significant_line(source, context, options={})
    if !source.beginning_of_line? && source.chars_left > 0
      if options[:allow_midline_eof]
        return [true, 0, false, source.bytepos]
      end

      return non_line_start(source, context) unless options[:scan_from_midline]

      consume_line_ending_after_content(source)
    end

    loop do
      break if source.chars_left.zero?

      blank_line_start = source.bytepos
      if blank_line?(source, @blank_lines == :ignore)
        case @blank_lines
        when :ignore then next
        when :normal then break
        when :error
          source.bytepos = blank_line_start
          return line_error(source, context, 'Blank lines are not allowed')
        end
      end

      comment_line_start = source.bytepos
      if comment_line?(source, @comment_lines == :ignore)
        case @comment_lines
        when :ignore then next
        when :normal then break
        when :error
          source.bytepos = comment_line_start
          return line_error(source, context, 'Comment lines are not allowed')
        end
      end

      break
    end

    measure_indentation(source, context)
  end

  def consume_line_ending_after_content(source)
    while source.chars_left > 0 && !line_ending?(source)
      source.consume(1)
    end

    consume_line_ending(source)
  end

  def non_line_start(source, context)
    [false, context.err_at(nil, source, 'Indentation can only change at a line start', source.pos)]
  end

  def blank_line?(source, consume)
    starting_at = source.bytepos
    consume_inline_whitespace(source)

    if line_ending?(source) || source.chars_left.zero?
      return false if source.chars_left.zero? && !source.beginning_of_line?

      if consume
        consume_line_ending(source)
      else
        source.bytepos = starting_at
      end
      true
    else
      source.bytepos = starting_at
      false
    end
  end

  def comment_line?(source, consume)
    return false unless @comments

    starting_at = source.bytepos
    consume_inline_whitespace(source)
    success, _ = @comments.apply(source, Parslet::Atoms::Context.new(nil), false)

    if success
      if consume
        while source.chars_left > 0 && !line_ending?(source)
          source.consume(1)
        end
        consume_line_ending(source)
      else
        source.bytepos = starting_at
      end
      true
    else
      source.bytepos = starting_at
      false
    end
  end

  def measure_indentation(source, context)
    line_start = source.bytepos
    width = 0

    while source.chars_left > 0
      if source.matches?(/ /)
        source.consume(1)
        width += 1
      elsif source.matches?(/[\t]/)
        source.consume(1)

        case @tab_policy
        when :reject
          success, cause = context.err_at(nil, source, 'Tab characters are not allowed', line_start)
          cause.indentation_error! if cause
          return [success, cause]
        when :character
          width += 1
        when :expand
          width += @tab_width - (width % @tab_width)
        end
      else
        break
      end
    end

    [true, width, source.chars_left.zero?, line_start]
  end


  def consume_inline_whitespace(source)
    while source.matches?(/[ \t]/)
      source.consume(1)
    end
  end

  def line_ending?(source)
    source.matches?(/[\r]\n/) || source.matches?(/[\r\n]/)
  end

  def consume_line_ending(source)
    if source.matches?(/[\r]\n/)
      source.consume(2)
    elsif source.matches?(/[\r\n]/)
      source.consume(1)
    end
  end

  def line_error(source, context, message)
    success, cause = context.err_at(nil, source, message, source.pos)
    cause.indentation_error! if cause
    [success, cause]
  end
  alias_method :mark_error, :line_error

  def line_option(value, default)
    case value || default
    when :ignore, true then :ignore
    when :normal, false, nil then :normal
    when :error then :error
    else raise ArgumentError, "Unknown indentation line option: #{value.inspect}"
    end
  end

  def tab_policy(value)
    case value
    when true then :character
    when false then :reject
    else TAB_POLICIES.fetch(value) do
      raise ArgumentError, "Unknown tab policy: #{value.inspect}"
    end
    end
  end

  def build_parser(parser)
    return nil unless parser
    return Parslet.str(parser) if parser.is_a?(String)
    return Parslet::Atoms::Dynamic.new(parser) if parser.is_a?(Proc)

    parser
  end

  def build_brackets(value)
    return {} if value == false
    return DEFAULT_BRACKETS.merge(value || {})
  end

  def default_bracket_key
    brackets.keys.first || raise(ArgumentError, 'No opening bracket is configured')
  end

  def default_bracket_value
    brackets.values.first || raise(ArgumentError, 'No closing bracket is configured')
  end
end
