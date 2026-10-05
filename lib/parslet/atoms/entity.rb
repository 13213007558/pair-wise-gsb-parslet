# This wraps pieces of parslet definition and gives them a name. The wrapped
# piece is lazily evaluated and cached. This has two purposes: 
#     
# * Avoid infinite recursion during evaluation of the definition
# * Be able to print things by their name, not by their sometimes
#   complicated content.
#
# You don't normally use this directly, instead you should generate it by
# using the structuring method Parslet.rule.
#
class Parslet::Atoms::Entity < Parslet::Atoms::Base
  attr_reader :name, :block

  # Instance path of the grammar module instance this entity belongs to
  # (if any). Used to qualify the rule name in error output, so that two
  # instances of the same module remain distinguishable.
  #
  attr_accessor :path

  def initialize(name, label=nil, &block)
    super()
    
    @name = name
    @label = label
    @block = block
    @parslet = nil
    @path = nil
  end

  def try(source, context, consume_all)
    parslet.apply(source, context, consume_all)
  end
  
  def parslet
    return @parslet unless @parslet.nil?
    @parslet = @block.call
    raise_not_implemented if @parslet.nil?
    @parslet.label = @label
    @parslet
  end

  def to_s_inner(prec)
    if path
      [path, name].join('.').upcase
    else
      name.to_s.upcase
    end
  end  
private 
  def raise_not_implemented
    trace = caller.reject {|l| l =~ %r{#{Regexp.escape(__FILE__)}}} # blatantly stolen from dependencies.rb in activesupport
    exception = NotImplementedError.new("rule(#{name.inspect}) { ... }  returns nil. Still not implemented, but already used?")
    exception.set_backtrace(trace)
    
    raise exception
  end
end
