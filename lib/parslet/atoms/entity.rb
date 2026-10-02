# This wraps pieces of parslet definition and gives one a name. The wrapped
# piece is lazily evaluated and cached.
class Parslet::Atoms::Entity < Parslet::Atoms::Base
  attr_reader :name, :block

  def initialize(name, label=nil, &block)
    super()

    @name = name
    @label = label
    @block = block
    @parslet = nil
  end

  def try(source, context, consume_all)
    old_pos = source.bytepos
    result = parslet.apply(source, context, consume_all)
    if context.replay_cached_entity?(self, old_pos)
      context.consume_replay_after_growth(self, old_pos)
      context.replay_cached_entity(self, source, old_pos)
    else
      result
    end
  end

  def parslet
    return @parslet unless @parslet.nil?

    @parslet = @block.call
    raise_not_implemented if @parslet.nil?
    @parslet.label = @label
    @parslet
  end

  def to_s_inner(prec)
    name.to_s.upcase
  end

  private

  def raise_not_implemented
    trace = caller.reject { |l| l =~ %r{#{Regexp.escape(__FILE__)}} }
    exception = NotImplementedError.new("rule(#{name.inspect}) { ... }  returns nil. Still not implemented, but already used?")
    exception.set_backtrace(trace)

    raise exception
  end
end
