# Commits to the nearest enclosing ordered choice after its wrapped parslet
# has matched. The wrapped result is returned unchanged.
#
class Parslet::Atoms::Commit < Parslet::Atoms::Base
  attr_reader :parslet

  def initialize(parslet)
    super()
    @parslet = parslet
  end

  def apply(source, context, consume_all)
    result = parslet.apply(source, context, consume_all)
    return result unless result.first
    context.commit!
    result
  end

  def to_s_inner(prec)
    "#{parslet.to_s(prec)}~"
  end
end
