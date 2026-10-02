module Parslet::Atoms
  class Context
    # Per-rule state used by the Warth-style packrat left-recursion algorithm.
    LeftRecursion = Struct.new(
      :rule, :position, :head, :seed, :seed_advance,
      :involved, :active, :growing, :scc, :forced_result
    )

    def initialize(reporter=Parslet::ErrorReporter::Tree.new)
      @cache = Hash.new { |h, k| h[k] = {} }
      @rules = Hash.new { |h, k| h[k] = {} }
      @active_rules = []
      @growing = false
      @reporter = reporter
      @captures = Parslet::Scope.new
    end

    def try_with_cache(obj, source, consume_all)
      beg = source.bytepos

      if @growing
        return obj.try(source, self, consume_all)
      end

      unless entry = lookup(obj, beg)
        result = obj.try(source, self, consume_all)
        set(obj, beg, [result, source.bytepos - beg]) if obj.cached? && !@growing
        return result
      end

      result, advance = entry
      source.bytepos = beg + advance
      result
    end

    def err_at(*args)
      @reporter ? [false, @reporter.err_at(*args)] : [false, nil]
    end

    def err(*args)
      @reporter ? [false, @reporter.err(*args)] : [false, nil]
    end

    def succ(*args)
      @reporter ? [true, @reporter.succ(*args)] : [true, nil]
    end

    def reporter?
      !@reporter.nil?
    end

    attr_reader :captures

    def scope
      captures.push
      yield
    ensure
      captures.pop
    end

    def active_left_recursion_seed(rule, source)
      beg = source.bytepos
      state = lookup_rule(rule, beg)
      answer_existing_rule(state, source, beg)
    end

    def rule_call(rule, source, consume_all, force_raw: false)
      beg = source.bytepos
      state = lookup_rule(rule, beg)

      return answer_existing_rule(state, source, beg) if state && (state.active || state.head.growing)

      state = new_rule_state(rule, source, beg)
      activate(state)
      # First evaluation plants failure seeds. If the same rule reaches its own
      # seed, the seed fails and ordered choice can fall through to a base case.
      result = yield
      deactivate(state)
      if state.involved
        grow_left_recursion(state, source, beg, result, source.bytepos - beg)
      else
        remove_rule_state(state)
        if force_raw
          source.bytepos = beg
          @cache.clear
          rule.parslet.apply(source, self, consume_all)
        else
          answer(result, source.bytepos - beg, source, beg)
        end
      end
    end

  private

    def answer_existing_rule(state, source, beg)
      if state.head.growing
        return answer(state.seed, state.seed_advance, source, beg) if state == state.head
        return grow_rule_member(state, source, beg)
      end

      detect_left_recursion(state, source, beg) if state.active
      answer(state.seed, state.seed_advance, source, beg)
    end

    def grow_left_recursion(state, source, beg, result, advance)
      # Re-evaluate the head using the best prefix so far until the prefix no
      # longer grows. Only prefixes that consumed input are accepted.
      state.growing = true
      @growing = true
      best, best_advance = result, advance

      begin
        return left_recursion_failure(state, source, best) unless best.first && best_advance > 0

        loop do
          seed_advance = best_advance
          start_growth_iteration(state, best, best_advance)
          source.bytepos = beg
          candidate = state.rule.evaluate_definition!(source, self, false)
          candidate_advance = source.bytepos - beg

          if candidate.first && candidate_advance >= seed_advance
            best = candidate
            best_advance = candidate_advance
          end

          break unless candidate.first && candidate_advance > seed_advance
        end

        answer(best, best_advance, source, beg)
      ensure
        state.growing = false
        @growing = false
        remove_left_recursion(state)
      end
    end

    def grow_rule_member(state, source, beg)
      return answer(state.forced_result, state.seed_advance, source, beg) if state.forced_result

      seed_advance = state.head.seed_advance
      activate(state)
      result = state.rule.evaluate_definition!(source, self, false)
      advance = source.bytepos - beg
      deactivate(state)

      if result.first && advance >= seed_advance
        update_seed(state, result, advance)
        state.forced_result = result
        answer(result, advance, source, beg)
      else
        answer(state.seed, state.seed_advance, source, beg)
      end
    end

    def start_growth_iteration(head, seed, advance)
      head.seed = seed
      head.seed_advance = advance
      head.scc.each do |state|
        next if state == head
        state.seed = seed
        state.seed_advance = advance
        state.forced_result = nil
      end
    end

    def detect_left_recursion(state, source, beg)
      head = state.head
      state.involved = true
      head.involved = true

      if index = @active_rules.index(head)
        @active_rules[(index + 1)..-1].each do |member|
          next if member.head == head
          member.head = head
          member.involved = true
          head.scc << member unless head.scc.include?(member)
        end
      end

      invalidate_cache_from(head.position)
      answer(state.seed, state.seed_advance, source, beg)
    end

    def left_recursion_failure(state, source, result)
      children = result && result.last ? [result.last] : []
      message = "Left recursion in rule #{state.rule.name.upcase} did not consume input"
      err(state.rule, source, message, children)
    end

    def new_rule_state(rule, source, beg)
      seed = err(rule, source, "Left recursion seed", [])
      state = LeftRecursion.new(
        rule, beg, nil, seed, 0, false, false, false, nil, nil
      )
      state.head = active_head_at(beg) || state
      state.scc = [state]
      set_rule(rule, beg, state)
      state
    end

    def invalidate_cache_from(position)
      @cache.keys.each { |pos| @cache.delete(pos) if pos >= position }
    end

    def remove_left_recursion(head)
      head.scc.each { |state| remove_rule_state(state) }
    end

    def remove_rule_state(state)
      @rules[state.position].delete(state.rule.object_id)
    end

    def lookup_rule(rule, position)
      @rules[position][rule.object_id]
    end

    def set_rule(rule, position, state)
      @rules[position][rule.object_id] = state
    end

    def update_seed(state, result, advance)
      return unless result.first && advance > state.seed_advance
      state.seed = result
      state.seed_advance = advance
    end

    def activate(state)
      state.active = true
      @active_rules.push(state)
    end

    def deactivate(state)
      state.active = false
      @active_rules.delete(state)
    end

    def active_head_at(position)
      state = @active_rules.reverse.find { |active| active.position == position }
      state && state.head
    end

    def answer(result, advance, source, beg)
      source.bytepos = result.first ? beg + advance : beg
      result
    end

    def lookup(obj, pos)
      @cache[pos][obj.object_id]
    end

    def set(obj, pos, value)
      @cache[pos][obj.object_id] = value
    end
  end
end
