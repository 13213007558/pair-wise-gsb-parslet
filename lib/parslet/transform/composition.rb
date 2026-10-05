class Parslet::Transform
  module Composable
    def apply(tree, context=nil)
      try_apply(tree, context).value!
    end

    # Runs this rewriter, then every other rewriter in order on the result.
    def compose(*rewriters)
      Sequence.new([self, *rewriters])
    end
    alias_method :>>, :compose

    # Returns the first strategy whose result is a match, including equal
    # results. Errors are never treated as no match.
    def first_success(*rewriters)
      FirstSuccess.new([self] + rewriters)
    end
    alias_method :otherwise, :first_success

    # Applies this strategy only to the first direct child that it matches.
    def one_child
      OneChild.new(self)
    end

    # Applies this strategy to every direct child. Every child must match.
    def all_children
      AllChildren.new(self)
    end

    # Repeats complete passes until no more change, a cycle, or the caller
    # budget is reached.
    def repeat_until_stable(budget: nil)
      RepeatUntilStable.new(self, budget)
    end
  end

  class Strategy
    include Composable

    def self.ensure_rewriter(rewriter)
      unless rewriter.respond_to?(:try_apply)
        raise ArgumentError, "#{rewriter.inspect} must respond to #try_apply"
      end
      rewriter
    end

  end

  class Sequence < Strategy
    def initialize(rewriters)
      rewriters = rewriters.flatten
      if rewriters.empty?
        raise ArgumentError, "compose requires at least one rewriter"
      end

      @rewriters = rewriters.map do |rewriter|
        Strategy.ensure_rewriter(rewriter)
      end
    end

    def try_apply(tree, context=nil)
      current = tree

      @rewriters.each do |rewriter|
        result = rewriter.try_apply(current, context)
        return Result.error(tree, result.exception) if result.error?
        return result if result.terminal?
        return Result.no_match(tree) if result.no_match?
        current = result.value
      end

      Result.match(tree, current)
    end
  end

  class FirstSuccess < Strategy
    def initialize(rewriters)
      rewriters = rewriters.flatten
      if rewriters.empty?
        raise ArgumentError, "first_success requires at least one rewriter"
      end

      @rewriters = rewriters.map { |rewriter| Strategy.ensure_rewriter(rewriter) }
    end

    def try_apply(tree, context=nil)
      @rewriters.each do |rewriter|
        result = rewriter.try_apply(tree, context)
        return Result.error(tree, result.exception) if result.error?
        return result if result.terminal?
        return result if result.success?
      end

      Result.no_match(tree)
    end
  end

  class OneChild < Strategy
    def initialize(rewriter)
      @rewriter = Strategy.ensure_rewriter(rewriter)
    end

    def try_apply(tree, context=nil)
      case tree
      when Hash
        tree.each do |key, child|
          result = @rewriter.try_apply(child, context)
          next if result.no_match?
          return Result.error(tree, result.exception) if result.error?
          return result if result.terminal?

          candidate = tree.merge(key => result.value)
          return Result.match(tree, candidate)
        end
      when Array
        tree.each_with_index do |child, index|
          result = @rewriter.try_apply(child, context)
          next if result.no_match?
          return Result.error(tree, result.exception) if result.error?
          return result if result.terminal?

          candidate = tree.dup
          candidate[index] = result.value
          return Result.match(tree, candidate)
        end
      end

      Result.no_match(tree)
    end
  end

  class AllChildren < Strategy
    def initialize(rewriter)
      @rewriter = Strategy.ensure_rewriter(rewriter)
    end

    def try_apply(tree, context=nil)
      case tree
      when Hash
        candidate = {}
        matched = false

        tree.each do |key, child|
          result = @rewriter.try_apply(child, context)
          return Result.error(tree, result.exception) if result.error?
          return result if result.terminal?
          return Result.no_match(tree) if result.no_match?
          matched ||= result.changed?
          candidate[key] = result.value
        end

        matched ? Result.match(tree, candidate) : Result.unchanged(tree)
      when Array
        results = tree.map do |child|
          result = @rewriter.try_apply(child, context)
          return Result.error(tree, result.exception) if result.error?
          return result if result.terminal?
          return Result.no_match(tree) if result.no_match?
          result
        end

        if results.any?(&:changed?)
          Result.match(tree, results.map(&:value))
        else
          Result.unchanged(tree)
        end
      else
        Result.unchanged(tree)
      end
    end
  end

  class IdentityRewriter < Strategy
    def try_apply(tree, context=nil)
      Result.unchanged(tree)
    end
  end

  class RepeatUntilStable < Strategy
    def initialize(rewriter, budget=nil)
      @rewriter = Strategy.ensure_rewriter(rewriter)
      @budget = budget

      if @budget && (!@budget.is_a?(Integer) || @budget < 0)
        raise ArgumentError, "budget must be a non-negative integer"
      end
    end

    def try_apply(tree, context=nil)
      states = [tree]
      current = tree
      iterations = 0

      loop do
        if @budget && iterations >= @budget
          return Result.budget_exhausted(current, iterations)
        end

        result = @rewriter.try_apply(current, context)
        return Result.error(tree, result.exception, iterations) if result.error?
        return Result.no_match(tree) if iterations.zero? && result.no_match?
        if result.no_match? || result.unchanged?
          stable = Result.match(tree, current)
          stable.iterations = iterations
          return stable
        end
        return result if result.terminal?

        iterations += 1
        current = result.value

        previous = states.index(current)
        if previous
          witness = CycleWitness.new(
            states: states.dup,
            repeat_from: previous,
            iteration: iterations
          )
          return Result.cycle(current, iterations, witness)
        end

        states << current
      end
    end
  end
end
