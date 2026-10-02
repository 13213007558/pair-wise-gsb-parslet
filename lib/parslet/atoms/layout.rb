# Layout atoms make indentation ("layout") significant in a grammar. Three
# relations are provided, see Parslet.indent, Parslet.same_indent and
# Parslet.dedent:
#
# * :indent - the next content line must be indented deeper than the current
#   level. The new level is entered (pushed).
# * :same - the next content line must be indented exactly at the current
#   level.
# * :dedent - the next content line must be indented less than the current
#   level. The current level is left (popped).
#
# All three skip blank lines (blank lines never establish a level) and must
# be placed where a line break is expected. :indent and :same consume the
# indentation of the next content line; :dedent only looks at it, leaving
# the indentation for the enclosing level's atoms.
#
# The indentation stack is maintained automatically by the parse context:
# failed alternatives roll it back and lookaheads cannot change it, so
# grammar authors never manage it by hand.
#
# Example:
#
#   rule(:block) { indent >> statement >> (same_indent >> statement).repeat >> dedent }
#
class Parslet::Atoms::Layout < Parslet::Atoms::Base
  attr_reader :relation

  def initialize(relation)
    super()

    @relation = relation
  end

  # Layout matching depends on the parse-time layout state; results must
  # never be replayed from the packrat cache.
  #
  def cached?
    false
  end

  def error_msgs
    @error_msgs ||= {
      indent:   "Expected indentation deeper than the current level",
      same:     "Expected indentation at the current level",
      dedent:   "Expected indentation less than the current level",
      line:     "Expected a line break before #{relation_name}",
      eof:      "Expected another line of input before #{relation_name}",
      base:     "Cannot dedent from the outermost level",
      unindent: "Unindent does not match any outer indentation level"
    }
  end

  def try(source, context, consume_all)
    error_pos = source.pos
    state = context.layout
    gap = Parslet::Layout.scan_gap(source,
      consume_indentation: relation != :dedent)

    width = nil
    unless gap.eof?
      begin
        width = state.policy.measure(gap.whitespace, gap.whitespace_bytepos)
      rescue Parslet::Layout::Violation => violation
        # Record the violation: if the parse fails as a whole, this is the
        # error the user sees (with exact line/column). The parse itself
        # continues, so alternatives can still roll back and retry.
        context.note_layout_violation(violation)
        return context.err_at(self, source, violation.message, violation.bytepos)
      end
    end

    case relation
    when :indent
      return context.err_at(self, source, error_msgs[:eof], error_pos) \
        if gap.eof?
      return context.err_at(self, source, error_msgs[:line], error_pos) \
        unless gap.line_start?

      if width > state.current
        state.push(width)
        return succ(nil)
      end

      context.err_at(self, source,
        "#{error_msgs[:indent]} (#{state.current}), got #{width}",
        gap.whitespace_bytepos)
    when :same
      return context.err_at(self, source, error_msgs[:eof], error_pos) \
        if gap.eof?
      return context.err_at(self, source, error_msgs[:line], error_pos) \
        unless gap.line_start?

      return succ(nil) if width == state.current

      context.err_at(self, source,
        "#{error_msgs[:same]} (#{state.current}), got #{width}",
        gap.whitespace_bytepos)
    when :dedent
      return context.err_at(self, source, error_msgs[:base], error_pos) \
        if state.base?

      if gap.eof?
        state.pop
        return succ(nil)
      end

      return context.err_at(self, source, error_msgs[:line], error_pos) \
        unless gap.line_start?

      if width < state.current
        state.pop
        if width > state.current
          # Record the violation: if the parse fails as a whole, this is
          # the error the user sees (with exact line/column). 
          context.note_layout_violation(
            Parslet::Layout::Violation.new(
              error_msgs[:unindent], gap.whitespace_bytepos))
          return context.err_at(self, source,
            error_msgs[:unindent], gap.whitespace_bytepos)
        end
        return succ(nil)
      end

      context.err_at(self, source,
        "#{error_msgs[:dedent]} (#{state.current}), got #{width}",
        gap.whitespace_bytepos)
    end
  end

  precedence BASE
  def to_s_inner(prec)
    relation_name.upcase
  end

private
  def relation_name
    relation == :same ? 'same_indent' : relation.to_s
  end
end
