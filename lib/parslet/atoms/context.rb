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
    def initialize(reporter=Parslet::ErrorReporter::Tree.new)
      @cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new
      @indentations = Hash.new { |h, k| h[k] = Parslet::Indentation::State.new }
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
      checkpoint = indentation_checkpoint
      semantic_checkpoint = indentation_semantic_checkpoint
        
      # Not in cache yet? Return early.
      cache_key = indentation_cache_key

      unless entry = @cache[beg][[obj.object_id, cache_key]]
        result = begin
          obj.try(source, self, consume_all)
        rescue Exception
          restore_indentation(checkpoint)
          raise
        end
    
        if result.first
          if obj.cached?
            @cache[beg][[obj.object_id, cache_key]] =
              [result, source.bytepos-beg, indentation_snapshot, semantic_checkpoint]
          end
        end
        
        return result
      end

      # the condition in unless has returned true, so entry is not nil.
      result, advance, resulting_indentation, semantic_start = entry

      # The data we're skipping here has been read before. (since it is in 
      # the cache) PLUS the actual contents are not interesting anymore since
      # we know obj matches at beg. So skip reading.
      source.bytepos = beg + advance
      if result.first
        restore_semantic_indentation(semantic_start)
        restore_indentation(resulting_indentation)
      else
        restore_indentation(checkpoint)
      end
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
      begin
        yield
      end
    ensure
      captures.pop
    end

    def indentation_state(policy)
      @indentations[policy.object_id]
    end

    def indentation_transaction
      checkpoint = indentation_checkpoint
      result = yield
      (@indentations.keys - checkpoint.keys).each do |object_id|
        checkpoint[object_id] = nil
      end
      [checkpoint, result]
    end

    def rollback_indentation_transaction(checkpoint)
      restore_indentation(checkpoint)
    end

    def indentation_cache_key
      @indentations.each_with_object({}) do |(object_id, state), key|
        key[object_id] = state.key
      end
    end

    def indentation_checkpoint
      @indentations.each_with_object({}) do |(object_id, state), checkpoint|
        checkpoint[object_id] = state.checkpoint
      end
    end

    def indentation_snapshot
      indentation_checkpoint
    end

    def indentation_semantic_checkpoint
      @indentations.each_with_object({}) do |(object_id, state), checkpoint|
        checkpoint[object_id] = state.semantic_checkpoint
      end
    end

    def restore_indentation(checkpoint)
      checkpoint.each do |object_id, state_checkpoint|
        if state_checkpoint
          state = @indentations[object_id]
          state.restore(state_checkpoint)
        else
          @indentations.delete(object_id)
        end
      end
    end

    def restore_semantic_indentation(checkpoint)
      checkpoint.each do |object_id, semantic_state|
        @indentations[object_id].restore_semantic(semantic_state)
      end
    end

  private 
    # NOTE These methods use #object_id directly, since that seems to bring the
    # most performance benefit. This is a hot spot; going through
    # Atoms::Base#hash doesn't yield as much.
    #
    def lookup(obj, pos)
      @cache[pos][[obj.object_id, indentation_cache_key]]
    end
  end
end
