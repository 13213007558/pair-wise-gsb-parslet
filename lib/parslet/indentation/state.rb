class Parslet::Indentation::State
  class Mismatch < StandardError
  end

  attr_reader :levels, :brackets, :last_line_start, :last_position, :last_width, :last_eof

  def initialize(levels=[0], brackets=[], last_line_start=nil, last_position=nil, last_width=nil, last_eof=false)
    @levels = levels
    @brackets = brackets
    @last_line_start = last_line_start
    @last_position = last_position
    @last_width = last_width
    @last_eof = last_eof
  end

  def current_level
    @levels.last
  end

  def push(level)
    @levels << level
  end

  def pop_to(level)
    index = @levels.rindex(level)
    raise Mismatch unless index && index < @levels.size - 1

    @levels.slice!(index + 1..-1)
  end

  def pop
    @levels.pop if @levels.size > 1
  end

  def reset_levels
    @levels = [0]
  end

  def open_bracket(close)
    @brackets << close
  end

  def close_bracket(close)
    expected = @brackets.last
    raise Mismatch, "Expected #{expected.inspect}, but got #{close.inspect}" unless expected == close

    @brackets.pop
  end

  def inside_brackets?
    !@brackets.empty?
  end

  def checkpoint
    [
      @levels.dup,
      @brackets.dup,
      @last_line_start,
      @last_position,
      @last_width,
      @last_eof
    ]
  end

  def restore(checkpoint)
    @levels, @brackets, @last_line_start, @last_position, @last_width,
      @last_eof = checkpoint
  end

  def key
    [@levels.dup, @brackets.dup]
  end

  def semantic_checkpoint
    [@levels.dup, @brackets.dup]
  end

  def restore_semantic(checkpoint)
    @levels, @brackets = checkpoint.map(&:dup)
  end

  def mark_line(line_start, position, width, eof)
    @last_line_start = line_start
    @last_position = position
    @last_width = width
    @last_eof = eof
  end
end
