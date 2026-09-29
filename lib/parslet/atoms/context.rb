module Parslet::Atoms
  # Helper class that implements a transient cache that maps position and
  # parslet object to results. This is used for memoization in the packrat
  # style. 
  #
  # Also, error reporter is stored here and error reporting happens through
  # this class. This makes the reporting pluggable. 
  #
  class Context
    # Marker stored in the cache while a rule (Atoms::Entity) is being
    # evaluated at a given position. If the rule is applied recursively at
    # the same position during its own evaluation, the marker is what makes
    # the recursion detectable; it then collects the current best parse
    # (the 'seed') and a RecursionHead describing the cycle.
    #
    class EvaluatingRule
      # object_id of the rule this marker belongs to.
      attr_reader :rule

      # Current best parse of the rule: [result, advance] or nil if the
      # rule has not produced any parse yet.
      attr_accessor :seed

      # RecursionHead for the cycle this rule is part of, or nil if no
      # left recursion has been detected.
      attr_accessor :head

      def initialize(rule)
        @rule = rule
        @seed = nil
        @head = nil
      end
    end

    # Describes a left-recursive cycle of rules at one input position. 
    # While the cycle is grown (see Context#grow_left_recursion), all 
    # involved rules are re-evaluated once per iteration so that indirect 
    # left recursion (a -> b -> a) converges as well.
    #
    class RecursionHead
      # object_ids of all rules that take part in the cycle.
      attr_reader :involved

      def initialize(rule)
        @rule = rule
        @involved = [rule]
        @reevaluate = []
      end

      def involve(rule)
        @involved << rule unless @involved.include?(rule)
      end

      # Starts a new growth iteration: all involved rules except the head
      # rule itself must be re-evaluated (instead of served from cache).
      #
      def reevaluation!
        @reevaluate = @involved - [@rule]
      end

      # Returns true if the given rule must be re-evaluated during the
      # current growth iteration. Each rule is re-evaluated at most once
      # per iteration.
      #
      def reevaluate?(obj)
        @reevaluate.delete(obj.object_id) ? true : false
      end
    end

    # @param reporter [#err, #err_at] Error reporter (leave empty for default 
    #   reporter)
    # @param left_recursion [Boolean] Enable support for direct and indirect
    #   left-recursive rules (default: false). See Context#try_with_cache.
    #
    def initialize(reporter=Parslet::ErrorReporter::Tree.new, left_recursion: false)
      @cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new
      @left_recursion = left_recursion
      @rule_stack = []
      @heads = {}
    end

    # Returns true if left-recursive rules are supported in this parse.
    #
    def left_recursion?
      @left_recursion
    end
    
    # Caches a parse answer for obj at source.pos. Applying the same parslet
    # at one position of input always yields the same result, unless the input
    # has changed. 
    #
    # We need the entire source here so we can ask for how many characters 
    # were consumed by a successful parse. Imitation of such a parse must 
    # advance the input pos by the same amount of bytes.
    #
    def try_with_cache(obj, source, consume_all)
      beg = source.bytepos

      entry = lookup(obj, beg)

      # While a left-recursive cycle is grown at this position, cached
      # results of non-rule atoms at this position are stale: they were
      # computed against a previous (shorter) seed of the recursive rule.
      # Re-evaluate them against the current seed instead. Entries at other
      # positions stay valid and keep the packrat cache effective.
      if entry && @left_recursion && @heads[beg] &&
          !obj.is_a?(Parslet::Atoms::Entity)
        entry = nil
      end

      # Not in cache yet? Return early.
      unless entry
        if @left_recursion && obj.is_a?(Parslet::Atoms::Entity)
          # While a left-recursive cycle is grown at this position, rules
          # that are not part of the cycle cannot contribute to it and are
          # not evaluated.
          if @heads[beg]
            return lr_failure
          end
          return apply_rule(obj, source, beg)
        end

        result = obj.try(source, self, consume_all)
    
        if obj.cached?
          set obj, beg, [result, source.bytepos-beg]
        end
        
        return result
      end

      if @left_recursion && obj.is_a?(Parslet::Atoms::Entity)
        # The rule is currently being evaluated at this very position: we
        # found left recursion.
        if entry.is_a?(EvaluatingRule)
          return apply_recursive(obj, entry, source, beg)
        end

        # During growth of a left-recursive cycle, involved rules are
        # re-evaluated once per iteration against the current best parse.
        if (head = @heads[beg]) && head.reevaluate?(obj)
          result = obj.try(source, self, false)
          set obj, beg, [result, source.bytepos - beg]
          return result
        end
      end

      # the condition in unless has returned true, so entry is not nil.
      result, advance = entry

      # The data we're skipping here has been read before. (since it is in 
      # the cache) PLUS the actual contents are not interesting anymore since
      # we know obj matches at beg. So skip reading.
      source.bytepos = beg + advance
      return result
    end  
    
    # Report an error at a given position. 
    # @see ErrorReporter
    #
    def err_at(*args)
      return [false, @reporter.err_at(*args)] if @reporter
      return [false, nil]
    end
    
    # Report an error. 
    # @see ErrorReporter
    #
    def err(*args)
      return [false, @reporter.err(*args)] if @reporter
      return [false, nil]
    end

    # Report a successful parse.
    # @see ErrorReporter::Contextual
    #
    def succ(*args)
      return [true, @reporter.succ(*args)] if @reporter
      return [true, nil]
    end

    # Returns the current captures made on the input (see
    # Parslet::Atoms::Base#capture). Use as follows: 
    # 
    #   context.captures[:foobar] # => returns capture :foobar
    #
    attr_reader :captures
    
    # Starts a new scope. Use the #scope method of Parslet::Atoms::DSL
    # to call this. 
    #
    def scope
      captures.push
      yield
    ensure
      captures.pop
    end
    
  private 
    # Applies a rule (Atoms::Entity) at a position for the first time. If the
    # rule turns out to be left-recursive, the parse is grown iteratively;
    # otherwise this behaves exactly like a normal cache miss.
    #
    # Note that in left recursion mode, rules are always evaluated with
    # consume_all disabled; the flag is enforced by Atoms::Base#apply on the
    # final (longest) result. This keeps intermediate growth candidates from
    # failing just because they don't consume all input yet.
    #
    def apply_rule(rule, source, pos)
      marker = EvaluatingRule.new(rule.object_id)
      set(rule, pos, marker)
      @rule_stack.push(marker)

      capture_state = @captures.snapshot
      result = rule.try(source, self, false)
      advance = result.first ? source.bytepos - pos : 0

      @rule_stack.pop

      head = marker.head
      unless head
        # No left recursion was detected: a regular cache miss.
        set(rule, pos, [result, advance])
        return result
      end

      # Left recursion: iteratively grow the seed into the longest parse.
      marker.seed = [result, advance]
      grow_left_recursion(rule, source, pos, marker, head, capture_state)
    end

    # Handles a recursive application of a rule that is already being
    # evaluated at the same position. Records the cycle and answers with
    # the current seed (failure if there is none yet), which gives the
    # ordered alternatives of the rule a chance to produce a base parse.
    #
    def apply_recursive(rule, marker, source, pos)
      head = marker.head ||= RecursionHead.new(rule.object_id)

      # All rules on the evaluation stack from the recalled rule upwards
      # take part in the cycle; they must be re-evaluated while growing.
      if (index = @rule_stack.index(marker))
        @rule_stack[index..-1].each { |m| head.involve(m.rule) }
      end

      if (seed = marker.seed)
        result, advance = seed
        source.bytepos = pos + advance
        return result
      end

      lr_failure
    end

    # Failure value for the internal bookkeeping of left recursion (seed
    # misses, rules outside a cycle). These failures are an artifact of the
    # seed growing algorithm, not real parse errors; they are therefore not
    # passed through the error reporter, which would otherwise track them
    # as (irrelevant) deepest errors.
    #
    def lr_failure
      [false, nil]
    end

    # Grows the seed parse of a left-recursive rule at a given position. The
    # rule body is re-evaluated while each candidate consumes strictly more
    # input than the current best parse; since input is finite, this
    # progress condition guarantees termination. Candidates that fail or
    # don't make progress end the growth.
    #
    # Capture/scope state is reset before every candidate and restored to
    # the winning candidate's state afterwards, so state never leaks from
    # one candidate into the next.
    #
    def grow_left_recursion(rule, source, pos, marker, head, capture_state)
      best_result, best_advance = marker.seed
      best_state = @captures.snapshot

      @heads[pos] = head
      begin
        loop do
          head.reevaluation!
          source.bytepos = pos
          @captures.restore(capture_state)

          candidate = rule.try(source, self, false)
          break unless candidate.first

          candidate_advance = source.bytepos - pos
          break if candidate_advance <= best_advance

          best_result = candidate
          best_advance = candidate_advance
          best_state = @captures.snapshot
          set(rule, pos, [best_result, best_advance])
        end
      ensure
        @heads.delete(pos)
      end

      # Cache entries of the other rules in the cycle were computed against
      # intermediate seeds; drop them so that later lookups re-evaluate.
      head.involved.each do |rule_id|
        @cache[pos].delete(rule_id) unless rule_id == rule.object_id
      end

      if best_result.first
        set(rule, pos, [best_result, best_advance])
        @captures.restore(best_state)
        source.bytepos = pos + best_advance
      else
        set(rule, pos, [best_result, 0])
        @captures.restore(capture_state)
      end

      best_result
    end

    # NOTE These methods use #object_id directly, since that seems to bring the
    # most performance benefit. This is a hot spot; going through
    # Atoms::Base#hash doesn't yield as much.
    #
    def lookup(obj, pos)
      @cache[pos][obj.object_id] 
    end
    def set(obj, pos, val)
      @cache[pos][obj.object_id] = val
    end
  end
end
