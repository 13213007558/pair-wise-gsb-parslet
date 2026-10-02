# Commits the parser to the choice currently being made. Once a cut has
# been crossed, the innermost enclosing alternative will not try any of
# its remaining alternatives; a later failure is reported directly instead
# of backtracking into a completely different branch.
#
# The commit is scoped to the innermost enclosing choice only: outer
# alternatives still get to try their remaining alternatives. Cuts that
# are crossed inside a lookahead (positive or negative) never leave commit
# state behind, since lookaheads are speculative.
#
# Example:
#
#   # Once 'section' has been read, a failure in the body is reported
#   # directly; 'other_section' is never tried.
#   (str('section') >> cut >> body) | other_section
#
class Parslet::Atoms::Cut < Parslet::Atoms::Base
  def try(source, context, consume_all)
    context.cut!
    succ(nil)
  end

  # Cut only produces a side effect (the commit); caching it would skip
  # that side effect on cache hits.
  #
  def cached?
    false
  end

  def to_s_inner(prec)
    'cut'
  end
end
