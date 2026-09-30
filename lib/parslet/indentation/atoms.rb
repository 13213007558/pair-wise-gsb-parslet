class Parslet::Indentation::Level < Parslet::Atoms::Base
  attr_reader :policy, :kind

  def initialize(policy, kind)
    super()
    @policy = policy
    @kind = kind
  end

  def try(source, context, consume_all)
    state = context.indentation_state(policy)
    if kind != :dedent && state.last_position == source.bytepos
      width = state.last_width
      eof = state.last_eof
      line_start = state.last_line_start
    else
      prepared = policy.significant_line(
        source,
        context,
        scan_from_midline: kind == :dedent,
        allow_midline_eof: kind == :dedent)
      return prepared unless prepared.first

      width = prepared[1]
      eof = prepared[2]
      line_start = prepared[3]
    end

    state.mark_line(line_start, source.bytepos, width, eof)

    return succ(nil) if state.inside_brackets?

    eof = source.chars_left.zero? if kind == :dedent

    result = case kind
    when :same
      same(source, context, state, width, eof, line_start)
    when :indent
      indent(source, context, state, width, eof, line_start)
    when :dedent
      dedent(source, context, state, width, eof, line_start)
    end
    result
  end

  def to_s_inner(prec)
    "INDENTATION_#{kind.to_s.upcase}"
  end

private
  def same(source, context, state, width, eof, line_start)
    return context.err_at(self, source, 'Premature end of input', line_start) if eof
    return succ(nil) if width == state.current_level

    mismatch(source, context, state.current_level, width, line_start)
  end

  def indent(source, context, state, width, eof, line_start)
    return context.err_at(self, source, 'Premature end of input', line_start) if eof
    if width > state.current_level
      state.push(width)
      return succ(nil)
    end

    mismatch(source, context, state.current_level, width, line_start)
  end

  def dedent(source, context, state, width, eof, line_start)
    if eof
      if state.levels.size > 1
        state.pop
        return succ(nil)
      end

      return context.err_at(self, source, 'Premature end of input', line_start)
    end

    state.pop_to(width)
    succ(nil)
  rescue Parslet::Indentation::State::Mismatch
    return mismatch(source, context, state.current_level, width, line_start)
  end

  def mismatch(source, context, expected, actual, line_start)
    context.err_at(
      self,
      source,
      "Expected indentation of #{expected}, but got #{actual}",
      line_start)
  end
end

class Parslet::Indentation::End < Parslet::Atoms::Base
  attr_reader :policy

  def initialize(policy)
    super()
    @policy = policy
  end

  def try(source, context, consume_all)
    state = context.indentation_state(policy)
    prepared = policy.significant_line(source, context, scan_from_midline: true)
    return prepared unless prepared.first

    eof = prepared[2]
    state.mark_line(prepared[3], source.bytepos, prepared[1], eof)

    if state.inside_brackets?
      return policy.mark_error(
        source,
        "Expected closing bracket #{state.brackets.last.inspect} before end of input")
    end

    return context.err_at(self, source, 'Expected end of input', source.pos) unless eof

    state.reset_levels
    state.mark_line(source.bytepos, source.bytepos, 0, true)
    succ(nil)
  end

  def to_s_inner(prec)
    'INDENTATION_EOF'
  end
end

class Parslet::Indentation::Bracket < Parslet::Atoms::Base
  attr_reader :policy, :delimiter, :direction, :matching_delimiter

  def initialize(policy, direction, delimiter, matching_delimiter=nil)
    super()
    @policy = policy
    @direction = direction
    @literal = delimiter
    @delimiter = Parslet.str(delimiter)
    @matching_delimiter = matching_delimiter || delimiter
  end

  def try(source, context, consume_all)
    state = context.indentation_state(policy)
    success, value = result = delimiter.apply(source, context, false)
    unless success
      if direction == :close && state.brackets.last == @literal
        success, marked = policy.mark_error(
          source,
          context,
          "Expected closing bracket #{@literal.inspect} before end of input")
        return [success, marked]
      end

      return result
    end

    if direction == :open
      state.open_bracket(matching_delimiter)
    else
      state.close_bracket(@literal)
    end

    result
  rescue Parslet::Indentation::State::Mismatch => error
    success, cause = context.err_at(self, source, error.message, source.pos)
    cause.indentation_error! if cause
    [success, cause]
  end

  def to_s_inner(prec)
    "INDENTATION_#{direction.to_s.upcase}(#{delimiter})"
  end
end
