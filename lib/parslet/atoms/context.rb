module Parslet::Atoms
  class Context
    # Transient packrat cache with Warth-style growing memo entries for
    # direct and indirect left recursion in named rules.
    def initialize(reporter=Parslet::ErrorReporter::Tree.new)
      @cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new
      @active = []
      @left_recursion_entries = []
      @awaiting_cycles = []
      @prefix = false
      @growing = false
      @growing_heads = []
      @growing_results = {}
      @grown = {}
      @replay_after_growth = {}
      @speculative = []
    end

    def try_with_cache(obj, source, consume_all)
      pos = source.bytepos
      entry = lookup(obj, pos)
      unless entry
        return obj.try(source, self, consume_all) unless obj.cached?

        unless obj.is_a?(Entity)
          result = obj.try(source, self, consume_all)
          remember(obj, pos, result, source.bytepos - pos)
          return result
        end

        if (grown = @grown[[obj.object_id, pos]])
          result, advance = grown
          source.bytepos = pos + advance
          @growing = false
          @prefix = false
          return result
        end

        if @growing
          head_key = @growing_heads.find { |object_id, _| object_id == obj.object_id }
          if head_key
            source.bytepos = head_key.last
            entry = lookup(obj, head_key.last)
            if entry.is_a?(Hash) && entry[:active]
              source.bytepos = head_key.last + entry[:advance].to_i
              return entry[:result]
            end
          end
        end

        entry = new_entry(obj, pos)
        result = obj.try(source, self, @prefix ? false : consume_all)
        finish_entry(entry, source, result)
        @active.pop

        if entry[:reentered]
          if entry[:deferred]
            entry[:deferred] = false
          else
            return grow(obj, pos, entry, source, consume_all)
          end
        end

        set(obj, pos, [result, entry[:advance]])
        result
      end

      if entry.is_a?(Hash)
        if entry[:active]
          if entry[:advance]
            source.bytepos = pos + entry[:advance]
            return entry[:result]
          end

          mark_reentry(entry, pos)
          return empty_left_recursion(obj, source)
        end

        source.bytepos = pos + entry[:advance].to_i
        entry[:result]
      else
        result, advance = entry
        source.bytepos = pos + advance
        result
      end
    end

    def growing_left_recursion?
      @prefix || @growing
    end

    def replay_cached_entity(obj, source, pos)
      entry = lookup(obj, pos)
      return unless entry.is_a?(Array)

      result, advance = entry
      source.bytepos = pos + advance
      result
    end

    def replay_cached_entity?(obj, pos)
      @replay_after_growth[[obj.object_id, pos]]
    end

    def consume_replay_after_growth(obj, pos)
      @replay_after_growth.delete([obj.object_id, pos])
    end

    def unconsumed_entity(obj, source, old_pos)
      offending_pos = source.pos
      offending_input = source.consume(10)
      source.bytepos = old_pos

      err_at(
        obj,
        source,
        "Don't know what to do with #{offending_input.to_s.inspect}",
        offending_pos
      )
    end

    def empty_left_recursion(obj, source)
      err_at(obj, source, "Left recursion in #{obj.inspect} did not consume input", source.pos)
    end

    def err_at(*args)
      return [false, @reporter.err_at(*args)] if @reporter
      [false, nil]
    end

    def err(*args)
      return [false, @reporter.err(*args)] if @reporter
      [false, nil]
    end

    def succ(*args)
      return [true, @reporter.succ(*args)] if @reporter
      [true, nil]
    end

    attr_reader :captures

    def scope
      captures.push
      yield
    ensure
      captures.pop
    end

    private

    def lookup(obj, pos)
      @cache[pos][obj.object_id]
    end

    def set(obj, pos, value)
      @cache[pos][obj.object_id] = value
    end

    def remember(obj, pos, result, advance)
      if @prefix
        @speculative << [pos, obj]
      else
        set(obj, pos, [result, advance])
      end
    end

    def new_entry(obj, pos)
      entry = {
        obj: obj,
        pos: pos,
        active: true,
        reentered: false,
        growing: false,
        deferred: false,
        result: nil,
        advance: nil
      }
      set(obj, pos, entry)
      @active << entry
      entry
    end

    def finish_entry(entry, source, result)
      entry[:active] = false
      entry[:result] = result
      entry[:advance] = source.bytepos - entry[:pos]

      if result.first && entry[:advance].to_i > 0
        @awaiting_cycles.each do |waiting|
          next unless waiting[:pos] == entry[:pos]

          waiting[:deferred] = true
          waiting[:result] = result
          waiting[:advance] = entry[:advance]
        end

        waiting = @awaiting_cycles.find do |candidate|
          candidate[:pos] == entry[:pos] && candidate[:obj].is_a?(Entity)
        end
        if waiting
          @awaiting_cycles.delete(waiting)
          set(waiting[:obj], entry[:pos], waiting)
          grow(waiting[:obj], entry[:pos], waiting, source, true)
        end
      end
    end

    def mark_reentry(entry, pos)
      entry[:reentered] = true
      @prefix = true
      index = @active.rindex { |active_entry| active_entry.equal?(entry) }
      return unless index

      @active[index..-1].each do |active_entry|
        active_entry[:reentered] = true if active_entry[:pos] == pos
        @left_recursion_entries << active_entry unless @left_recursion_entries.include?(active_entry)
      end

      @cache[pos].each_value do |cached_entry|
        next unless cached_entry.is_a?(Hash)

        cached_entry[:reentered] = true
        @left_recursion_entries << cached_entry unless @left_recursion_entries.include?(cached_entry)
      end
    end

    def grow(obj, pos, head, source, consume_all)
      successful = @left_recursion_entries.find do |entry|
        entry[:result]&.first && entry[:advance].to_i > 0
      end
      head = successful if successful

      if @growing
        result, advance = @growing_results[[obj.object_id, pos]] ||
          [empty_left_recursion(obj, source), 0]
        source.bytepos = pos + advance.to_i
        return result
      end

      @growing = true
      @growing_heads << [obj.object_id, pos]
      @growing_results[[obj.object_id, pos]] = [head[:result], head[:advance]]
      @grown[[obj.object_id, pos]] = [head[:result], head[:advance]]

      if head[:advance].to_i <= 0 || !head[:result].first
        successful = @left_recursion_entries.find do |cycle_entry|
          cycle_entry[:result]&.first && cycle_entry[:advance].to_i > 0
        end

        if successful
          head[:deferred] = true
          head[:active] = false
          @prefix = true
          return successful[:result]
        end

        if @left_recursion_entries.any? { |cycle_entry| cycle_entry[:result].nil? }
          head[:deferred] = true
          @awaiting_cycles << head
          pending = @left_recursion_entries.find do |cycle_entry|
            cycle_entry[:result].nil? && cycle_entry[:obj] != obj
          end

          if pending
            pending_result = pending[:obj].try(source, self, false)
            if pending_result.first
              pending_advance = source.bytepos - pos
              pending[:result] = pending_result
              pending[:advance] = pending_advance
              head[:result] = pending_result
              head[:advance] = pending_advance
              set(pending[:obj], pos, [pending_result, pending_advance])
              @grown[[pending[:obj].object_id, pos]] = [pending_result, pending_advance]
              @growing_results[[pending[:obj].object_id, pos]] = [pending_result, pending_advance]
              @replay_after_growth[[pending[:obj].object_id, pos]] = true
            end
          end
        end

        failure = empty_left_recursion(obj, source)
        @active.each do |active_entry|
          next unless active_entry[:pos] == pos

          set(active_entry[:obj], pos, [failure, 0])
        end
        set(obj, pos, [failure, 0])
        source.bytepos = pos
        @growing = false
        @prefix = false
        return failure
      end

      best_result = head[:result]
      best_advance = head[:advance]
      result = best_result
      local_advance = best_advance
      @left_recursion_entries.each do |cycle_entry|
        cycle_entry[:seed_result] ||= cycle_entry[:result]
        cycle_entry[:seed_advance] ||= cycle_entry[:advance]
      end

      begin
        loop do
          restore(source, pos, head, head[:result], head[:advance])
          result = obj.try(source, self, false)
          success, = result
          advance = source.bytepos - pos
          captures.pop

          if success && advance > local_advance
            best_result = result
            best_advance = advance
            local_advance = advance
            @growing_results[[obj.object_id, pos]] = [best_result, best_advance]
            @grown[[obj.object_id, pos]] = [best_result, best_advance]
            update_seeds(head, result, advance)
          else
            break
          end
        end
      end

      head[:active] = false
      head[:growing] = false
      head[:reentered] = false
      head[:result] = best_result
      head[:advance] = best_advance
      @prefix = false
      @growing = false
      @growing_heads.delete([obj.object_id, pos])
      @growing_results.delete([obj.object_id, pos])
      set(obj, pos, [best_result, best_advance])
      @grown[[obj.object_id, pos]] = [best_result, best_advance]
      @replay_after_growth[[obj.object_id, pos]] = true
      source.bytepos = pos + best_advance

      deferred = @left_recursion_entries.find do |entry|
        entry[:deferred] && entry[:pos] == pos
      end
      if deferred
        deferred[:deferred] = false
        deferred[:reentered] = true
        deferred[:active] = true
        deferred[:result] = best_result
        deferred[:advance] = best_advance
        set(deferred[:obj], pos, deferred)
        return grow(deferred[:obj], pos, deferred, source, consume_all)
      end

      continuation = @left_recursion_entries.find do |entry|
        entry[:obj] != obj &&
        entry[:pos] == pos &&
        entry[:result]&.first &&
          entry[:advance].to_i < (pos + source.chars_left)
      end
      if continuation
        seed_result = continuation[:seed_result] || continuation[:result]
        seed_advance = continuation[:seed_advance] || continuation[:advance]
        continuation[:growing] = true
        continuation[:reentered] = true
        continuation[:result] = seed_result
        continuation[:advance] = seed_advance
        continued = grow(continuation[:obj], pos, continuation, source, consume_all)
        if continued.first
          continued_advance = source.bytepos - pos
          if continued_advance > best_advance
            best_result = continued
            best_advance = continued_advance
            result = continued
            continuation[:seed_result] = continued
            continuation[:seed_advance] = continued_advance
          end
        end
      end

      if consume_all && source.chars_left > 0
        offending_pos = source.pos
        offending_input = source.consume(10)
        source.bytepos = pos
        result = err_at(
          obj,
          source,
          "Don't know what to do with #{offending_input.to_s.inspect}",
          offending_pos
        )
      end

      result
    end

    def restore(source, pos, head, result, advance)
      @speculative.uniq.each do |written_pos, written_obj|
        @cache[written_pos].delete(written_obj.object_id)
      end
      @speculative.clear
      source.bytepos = pos

      head[:active] = true
      head[:growing] = true
      head[:reentered] = true
      head[:result] = result
      head[:advance] = advance
      set(head[:obj], pos, head)
      @active << head unless @active.include?(head)
      @left_recursion_entries.each do |active_entry|
        active_entry[:active] = true
        active_entry[:growing] = true
        active_entry[:reentered] = true
        active_entry[:result] = result
        active_entry[:advance] = advance
      end
      captures.push
    end

    def update_seeds(head, result, advance)
      @cache[head[:pos]].each_value do |entry|
        next unless entry.is_a?(Hash) && entry[:growing]

        entry[:result] = result
        entry[:advance] = advance
      end
    end
  end
end
