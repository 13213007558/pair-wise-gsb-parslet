# Marks the boundary of a grammar module instance (see
# Parslet::GrammarModule). Parsing the wrapped parslet happens inside an
# isolated capture scope to keep captures local to the instance.
#
class Parslet::Atoms::InstanceBoundary < Parslet::Atoms::Base
  attr_reader :parslet, :path

  def initialize(parslet, path)
    super()

    @parslet, @path = parslet, path
  end

  def cached?
    false
  end

  def try(source, context, consume_all)
    context.isolated_scope do
      parslet.apply(source, context, consume_all)
    end
  end

  def to_s_inner(prec)
    path.to_s.upcase
  end
end
