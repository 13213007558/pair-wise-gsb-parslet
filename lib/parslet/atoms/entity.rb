# This wraps pieces of parslet definition and gives them a name. The wrapped
# piece is lazily evaluated and cached.
#
# You don't normally use this directly, instead you should generate it by
# using the structuring method Parslet.rule.
#
class Parslet::Atoms::Entity < Parslet::Atoms::Base
  attr_reader :name, :block

  def initialize(name, label=nil, &block)
    super()

    @name = name
    @label = label
    @block = block
    @parslet = nil
    @defining = false
  end

  def try(source, context, consume_all)
    if @defining
      context.rule_call(self, source, consume_all) do
        parslet.apply(source, context, false)
      end
    else
      parslet.apply(source, context, consume_all)
    end
  end

  def evaluate_definition!(source, context, consume_all)
    # While a rule body is being constructed, recursive references to this
    # same entity become packrat rule calls rather than ordinary cached atoms.
    @defining = true
    definition = block.call
    raise_not_implemented if definition.nil?
    return context.active_left_recursion_seed(self, source) if equal?(definition)

    @parslet = definition
    definition.label = label
    definition.apply(source, context, consume_all)
  ensure
    @defining = false
  end

  def parslet
    return @parslet unless @parslet.nil?
    definition = @block.call
    return raise_not_implemented if definition.nil?
    @parslet = definition
    @parslet.label = @label
    @parslet
  end

  def to_s_inner(prec)
    name.to_s.upcase
  end

private
  def raise_not_implemented
    trace = caller.reject {|l| l =~ %r{#{Regexp.escape(__FILE__)}}}
    exception = NotImplementedError.new(
      "rule(#{name.inspect}) { ... }  returns nil. Still not implemented, but already used?"
    )
    exception.set_backtrace(trace)

    raise exception
  end
end
