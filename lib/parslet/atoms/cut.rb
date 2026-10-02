# A cut (or commit) point inside an alternative. Once the parse has
# advanced past a cut, the innermost surrounding alternation is committed
# to the current branch: If the rest of the branch fails, no further
# alternatives are tried at that level and the failure is reported
# directly, instead of backtracking into sibling branches.
#
# The commit is scoped to the innermost enclosing alternation; outer
# alternations are unaffected and will keep trying their remaining
# branches. Cuts fired inside a lookahead (positive or negative) are
# discarded together with the speculation.
#
# Example:
#
#   # Once 'class' has been matched, don't try other statement kinds
#   # anymore; report errors in the class body directly.
#   str('class') >> cut >> class_body
#
class Parslet::Atoms::Cut < Parslet::Atoms::Base
  def try(source, context, consume_all)
    context.cut!
    succ(nil)
  end

  # Cut has a side effect on the parse (it commits the surrounding
  # alternation), so it must not be served from the packrat cache.
  #
  def cached?
    false
  end

  precedence BASE
  def to_s_inner(prec)
    'cut'
  end
end
