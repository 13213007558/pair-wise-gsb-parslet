
require 'parslet/pattern'
require 'parslet/transform/result'
require 'parslet/transform/composition'

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
# The default #apply performs one post-order pass: each node is replaced once
# and the replacement is not revisited in that pass. To rewrite replacement
# results deliberately, compose strategies and repeat them explicitly with
# #repeat_until_stable; that strategy reports a cycle witness instead of
# looping forever.
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
  include Composable
  
  class << self
    # FIXME: Only do this for subclasses?
    include Parslet
    
    # Define a rule for the transform subclass. 
    #
    def rule(expression, &block)
      @__transform_rules ||= []
      # Prepend new rules so they have higher precedence than older rules
      @__transform_rules.unshift([Parslet::Pattern.new(expression), block])
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

    # Returns a rewriter that matches every tree without changing it.
    def identity
      IDENTITY
    end

    # Builds a sequential composition of complete rewriting strategies.
    def compose(*rewriters)
      Sequence.new(rewriters)
    end

    # Builds a strategy that succeeds with the first matching strategy.
    def first_success(*rewriters)
      FirstSuccess.new(rewriters)
    end

    # Builds a strategy that changes only one direct child at a time.
    def one_child(rewriter)
      OneChild.new(rewriter)
    end

    # Builds a strategy that changes all direct children at once.
    def all_children(rewriter)
      AllChildren.new(rewriter)
    end

    # Repeats complete passes until stable, cyclic, or budgeted out.
    def repeat_until_stable(rewriter, budget: nil)
      RepeatUntilStable.new(rewriter, budget)
    end
  end
  
  def initialize(raise_on_unmatch=false, **options, &block)
    @raise_on_unmatch = options.fetch(:raise_on_unmatch, raise_on_unmatch)
    @traversal = options.fetch(:traversal, :postorder)

    unless [:postorder, :root].include?(@traversal)
      raise ArgumentError, "traversal must be :postorder or :root"
    end

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
  def rule(expression, &block)
    # Prepend new rules so they have higher precedence than older rules
    @rules.unshift([Parslet::Pattern.new(expression), block])
  end
  
  # Applies one rewriting pass and returns a Result. The default traversal is
  # the historical post-order traversal. Use traversal: :root when composing
  # traversal strategies such as one_child and all_children.
  #
  def try_apply(obj, context=nil)
    if @traversal == :root
      result = apply_rules(obj, context)
    else
      result = apply_postorder(obj, context)
    end

    if result.error?
      Result.error(obj, result.exception, result.iterations)
    else
      result
    end
  end

  # Applies the transformation and returns the rewritten value. Use #try_apply
  # to distinguish no match, unchanged success, change, and errors.
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
  #
  # def apply is provided by Composable.
  
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
  def call_on_match(bindings, block)
    if block
      if block.arity == 1
        return block.call(bindings)
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
  def apply_rules(elt, context)
    rules.each do |pattern, block|
      begin
        if pattern.match(elt, context)
          bindings = pattern.match(rewritable_copy(elt), context)
          value = call_on_match(bindings, block)
          return Result.match(elt, value)
        end
      rescue StandardError => exception
        return Result.error(elt, exception)
      end
    end
    
    if @raise_on_unmatch && elt.is_a?(Hash)
      elt_types = elt.map do |key, value|
        [ key, value.class ]
      end.to_h
      return Result.error(
        elt,
        NotImplementedError.new("Failed to match `#{elt_types.inspect}`")
      )
    else
      Result.no_match(elt)
    end
  end

  # @api private
  #
  def rewritable_copy(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, child), copy|
        copy[rewritable_copy(key)] = rewritable_copy(child)
      end
    when Array
      value.map { |child| rewritable_copy(child) }
    else
      value
    end
  end

  # @api private
  #
  def apply_postorder(obj, context)
    case obj
    when Hash
      candidate = {}
      children_changed = false
      children_matched = false

      obj.each do |key, value|
        result = apply_postorder(value, context)
        return result if result.error? || result.terminal?
        children_changed ||= result.changed?
        children_matched ||= result.success?
        candidate[key] = result.value
      end

      local = apply_rules(candidate, context)
      return local if local.error?
      return Result.match(obj, local.value) if local.success?
      if children_changed
        Result.match(obj, candidate)
      elsif children_matched
        Result.unchanged(obj)
      else
        Result.no_match(obj)
      end
    when Array
      results = obj.map do |value|
        result = apply_postorder(value, context)
        return result if result.error? || result.terminal?
        result
      end

      candidate = results.map(&:value)
      local = apply_rules(candidate, context)
      return local if local.error?
      return Result.match(obj, local.value) if local.success?
      if results.any?(&:changed?)
        Result.match(obj, candidate)
      elsif results.any?(&:success?)
        Result.unchanged(obj)
      else
        Result.no_match(obj)
      end
    else
      apply_rules(obj, context)
    end
  end
end

require 'parslet/context'

Parslet::Transform.const_set(:IDENTITY, Parslet::Transform::IdentityRewriter.new)
