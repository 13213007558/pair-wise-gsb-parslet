module Parslet::Atoms
  # Helper class that implements a transient cache that maps position and
  # parslet object to results. This is used for memoization in the packrat
  # style. 
  #
  # Also, error reporter is stored here and error reporting happens through
  # this class. This makes the reporting pluggable. 
  #
  class Context
    # @param reporter [#err, #err_at] Error reporter (leave empty for default 
    #   reporter)
    # @param left_recursion [Boolean] Enable the left recursion algorithm
    #   for all rules (entities) evaluated in this context. Individual rules
    #   can also opt in via the :left_recursive rule option.
    #
    def initialize(reporter=Parslet::ErrorReporter::Tree.new, left_recursion=false)
      @cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new

      @left_recursion = left_recursion
      # Frames for rules that are currently being evaluated under the left
      # recursion scheme; @lr_index maps [object_id, position] to the frame.
      @lr_frames = []
      @lr_index = {}
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

      if left_recursive?(obj)
        # Reentrant call of the same rule at the same input position: this
        # is left recursion. Return the current seed and flag the cycle, so
        # that the outermost evaluation can grow the seed afterwards.
        if frame = @lr_index[[obj.object_id, beg]]
          frame[:recursive] = true
          source.bytepos = beg + frame[:advance]
          return frame[:result]
        end

        # A completed evaluation of this rule at this position is in the
        # cache; replay it like any other cached result.
        if entry = lookup(obj, beg)
          result, advance = entry
          source.bytepos = beg + advance
          return result
        end

        return try_with_left_recursion(obj, source, beg)
      end

      # Not in cache yet? Return early.
      unless entry = lookup(obj, beg)
        result = obj.try(source, self, consume_all)
    
        if obj.cached?
          set obj, beg, [result, source.bytepos-beg]
        end
        
        return result
      end

      # the condition in unless has returned true, so entry is not nil.
      result, advance = entry

      # The data we're skipping here has been read before. (since it is in 
      # the cache) PLUS the actual contents are not interesting anymore since
      # we know obj matches at beg. So skip reading.
      source.bytepos = beg + advance
      return result
    end  

    # Evaluates a left recursive rule at the current position using the
    # seed-growing algorithm: the rule body is first evaluated with a
    # failing seed for its own recursive occurrences. If the rule was
    # indeed entered recursively during that evaluation, the seed is
    # grown by repeatedly reevaluating the body, each time using the best
    # result so far as the new seed (see #grow_left_recursion).
    #
    def try_with_left_recursion(obj, source, beg)
      key = [obj.object_id, beg]
      frame = {
        result: left_recursion_seed(obj, source),
        advance: 0,
        recursive: false,
        writes: [],
        beg: beg
      }
      @lr_index[key] = frame
      @lr_frames << frame

      begin
        pre_evaluation_captures = @captures.snapshot

        # Evaluate with consume_all switched off: intermediate seed
        # results legitimately consume only part of the input. The
        # consume_all check is enforced by the outermost #apply once the
        # final result of the rule is known.
        result = obj.try(source, self, false)
        frame[:result] = result
        frame[:advance] = source.bytepos - beg

        grow_left_recursion(obj, source, beg, frame,
          pre_evaluation_captures) if frame[:recursive]

        result = frame[:result]
        set(obj, beg, [result, frame[:advance]]) if obj.cached?
        result
      ensure
        @lr_frames.delete(frame)
        @lr_index.delete(key)
      end
    end

    # Grows the seed of a left recursive rule evaluation until the result
    # stops improving. A pass only replaces the current best if it succeeds
    # and consumes strictly more input; this progress condition guarantees
    # termination for a finite input.
    #
    # Between passes, all cache entries written by the previous pass are
    # invalidated (they were computed using the old seed) and the
    # capture/scope state is rolled back, so that no state leaks from one
    # candidate expansion into the next. When the loop finishes, the
    # captures of the best pass are restored.
    #
    def grow_left_recursion(obj, source, beg, frame, pre_evaluation_captures)
      best_result, best_advance = frame[:result], frame[:advance]
      success, _ = best_result

      if success
        # A recursive rule that succeeds without consuming any input is
        # nullable through its recursive arm: growing could never make
        # progress. This is a grammar bug, not a parse failure.
        if best_advance == 0
          raise Parslet::LeftRecursionError.new(
            "Left recursion in rule #{obj.respond_to?(:name) ? obj.name.inspect : obj.inspect} " \
            "can succeed without consuming input (nullable recursion). " \
            "Rewrite the rule so that every recursive cycle consumes input.")
        end

        best_captures = @captures.snapshot

        loop do
          # Install the current best as the seed for the next pass.
          frame[:result] = best_result
          frame[:advance] = best_advance

          # Invalidate cache entries produced with the previous seed and
          # roll back capture state to what it was before the rule ran.
          frame[:writes].each { |id| @cache[beg].delete(id) }
          frame[:writes].clear
          @captures.restore(pre_evaluation_captures)
          source.bytepos = beg

          result = obj.try(source, self, false)
          advance = source.bytepos - beg
          success, _ = result

          break unless success && advance > best_advance

          best_result, best_advance = result, advance
          best_captures = @captures.snapshot
        end

        frame[:result] = best_result
        frame[:advance] = best_advance
        @captures.restore(best_captures)

        # The last pass failed to improve the result and left the input
        # position wherever it failed; reposition to the end of the best
        # match, so callers see the position the result corresponds to.
        source.bytepos = beg + best_advance
      end
    end

    
    # True while no left recursive rule evaluation is in progress. While
    # seeds are grown, intermediate results legitimately consume only part
    # of the input; the consume_all check is therefore suppressed and only
    # enforced once the outermost evaluation completes.
    #
    def enforce_consume_all?
      @lr_frames.empty?
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
    # The initial seed for a left recursive evaluation: a failure. When
    # error reporting is active, the failure carries a real cause, so
    # that error trees built while the seed is in place stay well-formed.
    #
    def left_recursion_seed(obj, source)
      err(obj, source, 'Expected ' + obj.to_s(Parslet::Atoms::Precedence::OUTER))
    end

    # Returns true if the left recursion scheme applies to this atom. Only
    # entities (named rules) can ever be reentrant, since all recursion in
    # a grammar goes through them.
    #
    def left_recursive?(obj)
      obj.is_a?(Parslet::Atoms::Entity) &&
        (obj.left_recursive? || @left_recursion)
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

      # While left recursive rules are being evaluated, remember cache
      # writes in every open frame that shares the position of the write.
      # Only entries at the frame's own position can possibly depend on
      # the frame's seed (evaluation never revisits earlier positions),
      # so frames invalidate exactly those before reevaluating.
      @lr_frames.each { |frame|
        frame[:writes] << obj.object_id if frame[:beg] == pos
      }
    end
  end
end
