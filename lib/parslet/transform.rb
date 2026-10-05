
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
# A single #apply call cannot loop: each node is replaced only once during a
# post-order traversal, so replacement results are not immediately acted upon.
# Repeated rewriting is available explicitly through
# Parslet::Transform::Composable#repeat_until_stable; that strategy reports
# both cycles and caller supplied budgets.
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
# = Composable rewrites
#
# In addition to the original post-order traversal, transforms can be used as
# small strategies. #apply_result returns a Parslet::Transform::Result instead
# of only the resulting value, making +:no_match+, +:unchanged+ and
# +:changed+ observable:
#
#   fold.and_then(emit)               # apply both strategies in order
#   fold.first_successful(emit)      # fall through only for no match
#   fold.one_child                  # change the first matching direct child
#   fold.all_children               # change all direct children as one step
#   fold.repeat_until_stable(100)   # repeat until stable, cycle, or budget
#
# Real exceptions always propagate; they are not treated as a failed match.
# Structural rewrites build replacement hashes and arrays instead of mutating
# the input, so a later failure cannot leave a partially rewritten input.
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
  class Result < Struct.new(:status, :value, :iterations, :witness, :budget)
    def self.no_match(value)
      new(:no_match, value, 0, nil, nil)
    end

    def self.unchanged(value)
      new(:unchanged, value, 0, nil, nil)
    end

    def self.changed(value)
      new(:changed, value, 0, nil, nil)
    end

    def self.stable(value, iterations)
      new(:stable, value, iterations, nil, nil)
    end

    def self.cycle(value, iterations, witness)
      new(:cycle, value, iterations, witness, nil)
    end

    def self.budget_exceeded(value, iterations, budget)
      new(:budget_exceeded, value, iterations, nil, budget)
    end

    def self.attempt(value, original)
      value == original ? unchanged(value) : changed(value)
    end

    def no_match?
      status == :no_match
    end

    def matched?
      status != :no_match
    end
    alias_method :success?, :matched?

    def unchanged?
      status == :unchanged
    end

    def changed?
      status == :changed
    end

    def stable?
      status == :stable
    end

    def cycle?
      status == :cycle
    end

    def budget_exceeded?
      status == :budget_exceeded
    end

    def terminal?
      [:stable, :cycle, :budget_exceeded].include?(status)
    end

    def inspect
      "#<Parslet::Transform::Result #{status.inspect} #{value.inspect}>"
    end
  end

  module Composable
    # Runs this rewriter, then +other+ with the first result as input.
    def seq(other)
      Sequential.new(self, other)
    end
    alias_method :and_then, :seq

    # Runs +other+ only when this rewriter reports +:no_match+.
    def first_successful(other)
      FirstSuccessful.new(self, other)
    end
    alias_method :orelse, :first_successful
    alias_method :or_else, :first_successful

    # Applies this rewriter to the first direct child that matches.
    def one_child
      OneChild.new(self)
    end

    # Applies this rewriter to every direct child as one atomic rewrite.
    def all_children
      AllChildren.new(self)
    end

    # Repeats this rewriter until a value is stable, repeats, or +budget+
    # successful applications have been made.
    def repeat_until_stable(budget=100)
      RepeatUntilStable.new(self, budget)
    end

    private

    def as_rewriter(object)
      unless object.respond_to?(:apply_result)
        raise ArgumentError, "#{object.inspect} must respond to #apply_result"
      end

      object
    end
  end

  class Strategy
    include Composable

    def apply(obj, context=nil)
      apply_result(obj, context).value
    end
  end

  class Sequential < Strategy
    def initialize(first, second)
      @first = as_rewriter(first)
      @second = as_rewriter(second)
    end

    def apply_result(obj, context=nil)
      first_result = @first.apply_result(obj, context)
      return Result.no_match(obj) if first_result.no_match?
      return first_result if first_result.terminal?

      second_result = @second.apply_result(first_result.value, context)
      return Result.no_match(obj) if second_result.no_match?
      return second_result if second_result.terminal?

      Result.attempt(second_result.value, obj)
    end
  end

  class FirstSuccessful < Strategy
    def initialize(first, second)
      @first = as_rewriter(first)
      @second = as_rewriter(second)
    end

    def apply_result(obj, context=nil)
      first_result = @first.apply_result(obj, context)
      return first_result unless first_result.no_match?

      second_result = @second.apply_result(obj, context)
      return Result.no_match(obj) if second_result.no_match?
      return second_result if second_result.terminal?

      Result.attempt(second_result.value, obj)
    end
  end

  class OneChild < Strategy
    def initialize(rewriter)
      @rewriter = as_rewriter(rewriter)
    end

    def apply_result(obj, context=nil)
      each_child(obj) do |key, child|
        child_result = @rewriter.apply_result(child, context)
        next if child_result.no_match?

        return Result.attempt(replace_child(obj, key, child_result.value), obj)
      end

      Result.no_match(obj)
    end

    private

    def each_child(obj, &block)
      case obj
      when Hash
        obj.each_pair(&block)
      when Array
        obj.each_with_index { |child, index| block.call(index, child) }
      else
        [].each(&block)
      end
    end

    def replace_child(obj, key, value)
      if obj.is_a?(Hash)
        obj.merge(key => value)
      else
        replaced = obj.dup
        replaced[key] = value
        replaced
      end
    end
  end

  class AllChildren < Strategy
    def initialize(rewriter)
      @rewriter = as_rewriter(rewriter)
    end

    def apply_result(obj, context=nil)
      return Result.unchanged(obj) unless obj.is_a?(Hash) || obj.is_a?(Array)

      results = child_values(obj).map do |child|
        @rewriter.apply_result(child, context)
      end

      return Result.no_match(obj) if results.any?(&:no_match?)

      rebuilt = rebuild(obj, results)
      Result.attempt(rebuilt, obj)
    end

    private

    def child_values(obj)
      obj.is_a?(Hash) ? obj.values : obj
    end

    def rebuild(obj, results)
      if obj.is_a?(Hash)
        obj.keys.zip(results.map(&:value)).to_h
      else
        results.map(&:value)
      end
    end
  end

  class RepeatUntilStable < Strategy
    def initialize(rewriter, budget)
      unless budget.is_a?(Integer) && budget >= 1
        raise ArgumentError, "budget must be a positive Integer"
      end

      @rewriter = as_rewriter(rewriter)
      @budget = budget
    end

    def apply_result(obj, context=nil)
      current = obj
      seen = [current]
      iterations = 0

      @budget.times do
        previous = current
        result = @rewriter.apply_result(current, context)
        return Result.stable(previous, iterations) if result.no_match?
        return result if result.terminal?

        current = result.value
        iterations += 1

        if current == previous
          return Result.stable(current, iterations)
        elsif seen.include?(current)
          start = seen.index(current)
          witness = seen[start..-1] + [current]
          return Result.cycle(current, iterations, witness)
        end

        seen << current
      end

      Result.budget_exceeded(current, iterations, @budget)
    end
  end

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
  end
  
  def initialize(raise_on_unmatch=false, &block) 
    @raise_on_unmatch = raise_on_unmatch
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
  
  # Like #apply, but returns a Result that distinguishes a missing match
  # from a successful rule that returned an equal value.
  def apply_result(obj, context=nil)
    transformed, matched_children =
      case obj
      when Hash
        recurse_hash_result(obj, context)
      when Array
        recurse_array_result(obj, context)
      else
        [obj, false]
      end

    rules.each do |pattern, block|
      if bindings = pattern.match(transformed, context)
        value = call_on_match(bindings, block)
        return Result.attempt(value, obj)
      end
    end

    if @raise_on_unmatch && transformed.is_a?(Hash)
      elt_types = transformed.map do |key, value|
        [key, value.class]
      end.to_h
      raise NotImplementedError, "Failed to match `#{elt_types.inspect}`"
    end

    return Result.no_match(obj) unless matched_children
    Result.attempt(transformed, obj)
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
  #
  def apply(obj, context=nil)
    apply_result(obj, context).value
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
  def transform_elt(elt, context) 
    apply_result(elt, context).value
  end

  # @api private 
  #
  def recurse_hash(hsh, ctx) 
    recurse_hash_result(hsh, ctx).first
  end

  # @api private
  #
  def recurse_hash_result(hsh, ctx)
    transformed = {}
    matched = false

    hsh.each do |key, value|
      result = apply_result(value, ctx)
      transformed[key] = result.no_match? ? value : result.value
      matched ||= result.matched?
    end

    [transformed, matched]
  end
  # @api private 
  #
  def recurse_array(ary, ctx) 
    recurse_array_result(ary, ctx).first
  end

  # @api private
  #
  def recurse_array_result(ary, ctx)
    matched = false
    transformed = ary.map do |elt|
      result = apply_result(elt, ctx)
      matched ||= result.matched?
      result.no_match? ? elt : result.value
    end

    [transformed, matched]
  end

end

require 'parslet/context'
