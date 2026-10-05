# Zero-width ordered choice commitment. Reaching a cut commits only to the
# nearest Alternative choice frame active at that position. Other ordered
# choices outside that frame remain recoverable.
#
class Parslet::Atoms::Cut < Parslet::Atoms::Base
  def try(source, context, consume_all)
    context.commit!
    succ(nil)
  end

  def cached?
    false
  end

  def to_s_inner(prec)
    '~'
  end
end
