# A zero-width cut (commit) point. Reaching this atom commits the nearest
# enclosing ordered choice. If the selected alternative later fails, the
# failure bypasses remaining alternatives until it reaches that choice.
#
class Parslet::Atoms::Cut < Parslet::Atoms::Base
  def try(source, context, consume_all)
    context.cut
    succ(nil)
  end

  # A cut is a contextual side effect, so it must not be replayed from the
  # packrat cache in another choice scope.
  def cached?
    false
  end

  def to_s_inner(prec)
    'cut'
  end
end
