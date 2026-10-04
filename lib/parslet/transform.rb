
require 'parslet/pattern'

# Transforms an expression tree into something else. The transformation
# performs a depth-first, post-order traversal of the expression tree. During
# that traversal, each time a rule matches a node, the node is replaced by the
# result of the block associated to the rule. Otherwise the node is accepted
# as is into the result tree.
#
# This is almost what you would generally do with a tree visitor, except that
# you can match several levels of the tree at once. 
#
# As a consequence of this, the resulting tree will contain pieces of the
# original tree and new pieces. Most likely, you will want to transform the
# original tree wholly, so this isn't a problem.
#
# You will not be able to create a loop, given that each node will be replaced
# only once and then left alone. This means that the results of a replacement
# will not be acted upon. 
#
# Example: 
#
#   class Example < Parslet::Transform
#     rule(:string => simple(:x)) {  # (1)
#       StringLiteral.new(x)
#     }
#   end
#
# A tree transform (Parslet::Transform) is defined by a set of rules. Each
# rule can be defined by calling #rule with the pattern as argument. The block
# given will be called every time the rule matches somewhere in the tree given
# to #apply. It is passed a Hash containing all the variable bindings of this
# pattern match. 
#   
# In the above example, (1) illustrates a simple matching rule. 
#
# Let's say you want to parse matching parentheses and distill a maximum nest
# depth. You would probably write a parser like the one in example/parens.rb;
# here's the relevant part: 
#
#   rule(:balanced) {
#     str('(').as(:l) >> balanced.maybe.as(:m) >> str(')').as(:r)
#   }
#
# If you now apply this to a string like '(())', you get a intermediate parse
# tree that looks like this: 
#
#   {
#     l: '(', 
#     m: {
#       l: '(', 
#       m: nil, 
#       r: ')' 
#     }, 
#     r: ')' 
#   }
#
# This parse tree is good for debugging, but what we would really like to have
# is just the nesting depth. This transformation rule will produce that: 
#
#   rule(:l => '(', :m => simple(:x), :r => ')') { 
#     # innermost :m will contain nil
#     x.nil? ? 1 : x+1
#   }
#
# = Usage patterns
#
# There are four ways of using this class. The first one is very much
# recommended, followed by the second one for generality. The other ones are
# omitted here. 
#
# Recommended usage is as follows: 
#
#   class MyTransformator < Parslet::Transform
#     rule(...) { ... }
#     rule(...) { ... }
#     # ...
#   end
#   MyTransformator.new.apply(tree)
#
# Alternatively, you can use the Transform class as follows: 
#
#   transform = Parslet::Transform.new do
#     rule(...) { ... }
#   end
#   transform.apply(tree)
#
# = Execution context
#
# The execution context of action blocks differs depending on the arity of 
# said blocks. This can be confusing. It is however somewhat intentional. You 
# should not create fat Transform descendants containing a lot of helper methods, 
# instead keep your AST class construction in global scope or make it available
# through a factory. The following piece of code illustrates usage of global
# scope: 
#
#   transform = Parslet::Transform.new do
#     rule(...) { AstNode.new(a_variable) }
#     rule(...) { Ast.node(a_variable) } # modules are nice
#   end
#   transform.apply(tree)
#
# And here's how you would use a class builder (a factory):
#
#   transform = Parslet::Transform.new do
#     rule(...) { builder.add_node(a_variable) }
#     rule(...) { |d| d[:builder].add_node(d[:a_variable]) }
#   end
#   transform.apply(tree, :builder => Builder.new)
#
# As you can see, Transform allows you to inject local context for your rule
# action blocks to use. 
#
class Parslet::Transform
  # FIXME: Maybe only part of it? Or maybe only include into constructor
  # context?
  include Parslet   
  
  class << self
    # FIXME: Only do this for subclasses?
    include Parslet
    
    # Define a rule for the transform subclass. 
    #
    def rule(expression=nil, recursive: false, **keyword_expression, &block)
      if expression.nil? && !keyword_expression.empty?
        expression = keyword_expression
      end
      @__transform_rules ||= []
      # Prepend new rules so they have higher precedence than older rules
      @__transform_rules.unshift(
        [Parslet::Pattern.new(expression), block, { recursive: recursive }])
    end
    
    # Allows accessing the class' rules
    #
    def rules 
      @__transform_rules ||= []
    end

    def inherited(subclass)
      super
      subclass.instance_variable_set(:@__transform_rules, rules.dup)
    end
  end
  
  # @param options [Hash] options for every call to #apply on this instance
  # @option options [Boolean] :raise_on_unmatch raise NotImplementedError when
  #   a Hash node matches no rule (default: false)
  # @option options [Boolean] :graph treat the input as a directed graph
  #   (DAG or cyclic graph) instead of a tree (default: false)
  def initialize(raise_on_unmatch=false, **options, &block)
    if raise_on_unmatch.is_a?(Hash)
      options = raise_on_unmatch
      raise_on_unmatch = false
    end
    @raise_on_unmatch = options.key?(:raise_on_unmatch) ?
      options[:raise_on_unmatch] : raise_on_unmatch
    @graph = options.fetch(:graph, false)
    @rules = []
    
    if block
      instance_eval(&block)
    end
  end
  
  # Defines a rule to be applied whenever apply is called on a tree. A rule
  # is composed of two parts: 
  # 
  # * an *expression pattern*
  # * a *transformation block*
  #
  # If <tt>recursive: true</tt> is given, the rule declares support for
  # cycles in graph mode. Its action block may take a second argument that
  # receives a Parslet::Transform::RecursiveRef whenever the node being built
  # is reached through a cycle. Rules without this declaration cause a
  # Parslet::Transform::CyclicReferenceError whose message contains the
  # reference chain.
  def rule(expression=nil, recursive: false, **keyword_expression, &block)
    if expression.nil? && !keyword_expression.empty?
      expression = keyword_expression
    end
    # Prepend new rules so they have higher precedence than older rules
    @rules.unshift(
      [Parslet::Pattern.new(expression), block, { recursive: recursive }])
  end
  
  # Applies the transformation to a tree that is generated by Parslet::Parser
  # or a simple parslet. Transformation will proceed down the tree, replacing
  # parts/all of it with new objects. The resulting object will be returned. 
  #
  # Using the context parameter, you can inject bindings for the transformation.
  # This can be used to allow access to the outside world from transform blocks,
  # like so:
  # 
  #   document = # some class that you act on
  #   transform.apply(tree, document: document)
  #   
  # The above will make document available to all your action blocks: 
  #
  #   # Variant A
  #   rule(...) { document.foo(bar) }
  #   # Variant B
  #   rule(...) { |d| d[:document].foo(d[:bar]) }
  #
  # == Graph mode
  #
  # Passing <tt>graph: true</tt> (to the constructor or to this method)
  # switches from tree traversal to graph traversal. Nodes are identified by
  # object identity: a shared Hash or Array subtree is transformed exactly
  # once per #apply call and the transformed value is shared by every parent
  # that referenced the original node. Two roots transformed within one call
  # (e.g. as members of one outer Array) therefore share their result too.
  #
  # Cyclic input is supported through rules declared with
  # <tt>recursive: true</tt>. Such a rule receives an extra
  # Parslet::Transform::RecursiveRef whenever its own subtree is still being
  # transformed (a back edge). The rule controls what the reference resolves
  # to, either by returning the ref (it resolves to the rule result itself)
  # or by calling #resolve! on it. A rule reached through a cycle without
  # declaring <tt>recursive: true</tt> raises
  # Parslet::Transform::CyclicReferenceError, whose message contains the
  # reference chain.
  #
  # Graph mode only builds fresh Hash and Array containers, so a failed
  # transformation (a raised rule error or an undeclared cycle) leaves the
  # input graph untouched and the internal node cache is discarded. Plain
  # tree mode keeps its original traversal without this bookkeeping state.
  #
  # @param obj PORO ast to transform
  # @param context start context to inject into the bindings. 
  # @param options [Hash] per-call options
  # @option options [Boolean] :graph enable graph mode for this call only
  #
  def apply(obj=nil, context=nil, **options)
    graph = @graph
    # Normalize the call shapes accepted over the years:
    # * apply(tree)
    # * apply(tree, context_hash)
    # * apply(tree, foo: 'bar')      # keyword-style context in modern Ruby
    # * apply(a: 1)                  # keyword-style tree
    # * apply(tree, graph: true)
    if options.key?(:graph)
      graph = options.delete(:graph)
    end

    if context.nil?
      if obj.nil?
        # Only keyword arguments were given: they are the tree unless they
        # look like a context passed alongside a leaf... which cannot be
        # expressed positionally without braces anyway.
        obj = options unless options.empty?
      elsif !options.empty?
        # Keyword arguments following the tree are the injected context.
        context = options
      end
    elsif !options.empty?
      context = context.merge(options)
    end
    return Parslet::Transform::GraphSession.new(self).apply(obj, context) if graph

    transform_elt(
      case obj
        when Hash
          recurse_hash(obj, context)
        when Array
          recurse_array(obj, context)
      else
        obj
      end, 
      context
    )
  end
  
  # Executes the block on the bindings obtained by Pattern#match, if such a match
  # can be made. Depending on the arity of the given block, it is called in 
  # one of two environments: the current one or a clean toplevel environment.
  #
  # If you would like the current environment preserved, please use the 
  # arity 1 variant of the block. Alternatively, you can inject a context object
  # and call methods on it (think :ctx => self).
  #
  #   # the local variable a is simulated
  #   t.call_on_match(:a => :b) { a } 
  #   # no change of environment here
  #   t.call_on_match(:a => :b) { |d| d[:a] }
  #
  def call_on_match(bindings, block, recursive_ref=nil)
    if block
      if block.arity == 1
        return block.call(bindings)
      elsif block.arity == 2 || (block.arity < -1 && recursive_ref)
        return block.call(bindings, recursive_ref)
      else
        if recursive_ref && !bindings.key?(:ref)
          bindings = bindings.merge(:ref => recursive_ref)
        end
        context = Context.new(bindings)
        return context.instance_eval(&block)
      end
    end
  end
  
  # Allow easy access to all rules, the ones defined in the instance and the 
  # ones predefined in a subclass definition. 
  #
  def rules 
    self.class.rules + @rules
  end

  # @api private
  #
  def raise_on_unmatch?
    @raise_on_unmatch
  end

  # @api private
  #
  # Returns [bindings, block, options] for the first rule matching +elt+,
  # or nil when no rule matches.
  def match_rule(elt, context)
    rules.each do |pattern, block, options|
      if bindings = pattern.match(elt, context)
        return [bindings, block, options || {}]
      end
    end
    nil
  end
  
  # @api private 
  #
  def transform_elt(elt, context)
    bindings, block, _options = match_rule(elt, context)
    if block
      # Produces transformed value
      return call_on_match(bindings, block)
    end
    
    # No rule matched - element is not transformed
    if @raise_on_unmatch && elt.is_a?(Hash)
      elt_types = elt.map do |key, value|
        [ key, value.class ]
      end.to_h
      raise NotImplementedError, "Failed to match `#{elt_types.inspect}`"
    else
      return elt
    end
  end

  # @api private 
  #
  def recurse_hash(hsh, ctx) 
    hsh.inject({}) do |new_hsh, (k,v)|
      new_hsh[k] = apply(v, ctx)
      new_hsh
    end
  end
  # @api private 
  #
  def recurse_array(ary, ctx) 
    ary.map { |elt| apply(elt, ctx) }
  end
end

require 'parslet/context'
require 'parslet/transform/graph_session'
