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
# By default, Transform expects a tree: the same node object appearing more
# than once is visited more than once. When a parse result has had common
# subexpressions merged into a DAG (or a cyclic graph), pass <tt>graph:
# true</tt> to ::new or #apply to switch to the explicit graph mode. In that
# mode, every Hash/Array node is transformed at most once per #apply call;
# all parents of a shared node share the very same result object. Rules may
# opt in to cycles with <tt>cycle: true</tt> (see #rule); a cycle that no
# opted-in rule claims raises a CycleError whose message carries the
# reference chain of the cycle.
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
# = Graphs instead of trees
#
# To transform a DAG or cyclic graph produced by merging common
# subexpressions, use graph mode:
#
#   transform.apply(graph, nil, graph: true)
#
# A shared Hash/Array node is then transformed exactly once and every parent
# receives the same result object. Cycles require a rule that declares
# <tt>cycle: true</tt>; the forward Reference (a stand-in for the not-yet
# finished cyclic node) is exposed through the second block argument or the
# +reference+ helper:
#
#   rule(:node => subtree(:child), cycle: true) { |d, ref|
#     Node.new(d[:child], ref)
#   }
#
# A cycle with no such rule raises CycleError and leaves the input graph
# untouched.
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
  # Raised when transforming a graph in graph mode and a cycle is
  # encountered that no <tt>cycle: true</tt> rule claimed. The message
  # contains the chain of nodes leading back to the repeated node.
  #
  class CycleError < StandardError
    attr_reader :reference_chain

    def initialize(reference_chain)
      @reference_chain = reference_chain
      labels = reference_chain.map { |node| node.inspect }
      super("cycle detected while transforming graph: #{labels.join(' -> ')} " \
            << "(declare a rule with :cycle => true to build a controlled reference)")
    end
  end

  # A controlled forward reference handed to <tt>cycle: true</tt> rules.
  # Rules may place it into their result to point back at the cyclic node;
  # once that node has finished transforming, the reference resolves to its
  # result object. {Parslet::Transform#apply} performs this resolution before
  # returning, so references never escape a successful transformation.
  #
  class Reference
    # The original node the reference points back to.
    attr_reader :target
    # The chain of original nodes that led from the target back to itself.
    attr_reader :reference_chain

    def initialize(original_node, reference_chain)
      @target = nil
      @reference_chain = reference_chain
    end

    # @api private
    #
    # Records the chain of original nodes that closes the cycle and binds
    # the reference to the finished result. Called by the graph session.
    #
    def bind(result, reference_chain=nil)
      @target = result
      @reference_chain = reference_chain if reference_chain
      self
    end

    def inspect
      "#<#{self.class} target=#{@target.inspect}>"
    end
  end

  # FIXME: Maybe only part of it? Or maybe only include into constructor
  # context?
  include Parslet

  class << self
    # FIXME: Only do this for subclasses?
    include Parslet

    # Define a rule for the transform subclass.
    #
    # Options:
    # cycle:: when true, the rule may build a controlled reference when its
    #   node participates in a cycle. Without this, a cyclic node that
    #   matches this rule raises CycleError instead (graph mode only).
    #
    def rule(*arguments, **options, &block)
      expression, cycle = rule_arguments(arguments, options)
      @__transform_rules = [] unless defined?(@__transform_rules)
      # Prepend new rules so they have higher precedence than older rules
      @__transform_rules.unshift(
        [Parslet::Pattern.new(expression), block, cycle])
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

    def rule_arguments(arguments, options)
      if arguments.empty?
        [options.reject { |key, _| key == :cycle }, options.fetch(:cycle, false)]
      else
        [arguments.first, options.fetch(:cycle, false)]
      end
    end
  end

  # @param raise_on_unmatch raise when a Hash node matches no rule
  # @param graph when true, #apply runs in explicit graph mode: shared
  #   Hash/Array nodes are transformed only once and sharing is preserved
  #   through object identity.
  #
  def initialize(*arguments, **options, &block)
    @raise_on_unmatch = options.fetch(:raise_on_unmatch, arguments.first || false)
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
  # Pass <tt>cycle: true</tt> to allow the rule to build a controlled
  # reference when its node participates in a cycle. The forward reference
  # is bound like any other subtree (use +simple(:x)+ where it appears), is
  # passed as the block's second argument, and is available as the
  # +reference+ helper in arity-zero blocks.
  #
  def rule(*arguments, **options, &block)
    expression, cycle = rule_arguments(arguments, options)
    # Prepend new rules so they have higher precedence than older rules
    @rules.unshift(
      [Parslet::Pattern.new(expression), block, cycle])
  end

  # Normalizes the two ways of expressing a rule definition:
  #
  #   rule(simple(:x)) { ... }
  #   rule(:next => simple(:x), cycle: true) { ... }
  #
  # A bare trailing Hash is handed to +**options+, so the +:cycle+ flag
  # has to be peeled off of the pattern Hash in that case.
  #
  def rule_arguments(arguments, options)
    if arguments.empty?
      [options.reject { |key, _| key == :cycle }, options.fetch(:cycle, false)]
    else
      [arguments.first, options.fetch(:cycle, false)]
    end
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
  # @param obj PORO ast to transform
  # @param context start context to inject into the bindings.
  # @param graph run this single +apply+ in explicit graph mode, even when
  #   the transform was constructed as an ordinary tree transform.
  #
  def apply(*arguments, **options)
    # Ruby 4 hands a bare trailing Hash to +**options+. The three
    # supported shapes are:
    #
    #   apply(tree)
    #   apply(tree, context)
    #   apply(tree, nil, graph: true)
    #
    graph = options.fetch(:graph, nil)
    if arguments.empty?
      obj, context = options, nil
    else
      obj = arguments[0]
      context = arguments.fetch(1, options.empty? ? nil : options)
    end
    if graph || (graph.nil? && @graph)
      GraphSession.new(self, context).call(obj)
    else
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
  #   # no change of context here
  #   t.call_on_match(:a => :b) { |d| d[:a] }
  #
  def call_on_match(bindings, block, reference=nil)
    if block
      if block.arity == 1
        return block.call(bindings)
      elsif block.arity.abs >= 2
        return block.call(bindings, reference)
      elsif reference
        context = GraphContext.new(bindings, reference)
        return context.instance_eval(&block)
      else
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
  def transform_elt(elt, context, present_refs=nil)
    rules.each do |pattern, block, cycle|
      if bindings=pattern.match(elt, context)
        if present_refs && !present_refs.empty? && !cycle
          raise CycleError, present_refs.first.reference_chain
        end
        # Produces transformed value
        reference = present_refs && !present_refs.empty? ? present_refs.first : nil
        return call_on_match(bindings, block, reference)
      end
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

# @api private
#
# Execution context for cycle-aware rules. Behaves like Parslet::Context,
# but also exposes the controlled forward reference through +reference+.
#
class Parslet::Transform::GraphContext < Parslet::Context
  def initialize(bindings, reference)
    super(bindings)
    @__reference = reference
    singleton_class.send(:define_method, :reference) { @__reference }
  end
end

require 'parslet/transform/graph_session'
