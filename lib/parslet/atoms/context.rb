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
      @layout_indents = [0]
      @layout_configs = []
      @layout_phase = nil
      @default_layout_config = Parslet::Layout::Config.default
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
      cache_key = [obj.object_id, layout_snapshot, layout_config]
        
      # Not in cache yet? Return early.
      unless entry = lookup(beg, cache_key)
        result = obj.try(source, self, consume_all)
    
        if obj.cached?
          set(beg, cache_key, [
            result,
            source.bytepos-beg,
            result.first ? layout_snapshot : nil
          ])
        end
        
        return result
      end

      # the condition in unless has returned true, so entry is not nil.
      result, advance, indents = entry

      restore_layout_snapshot(indents) if indents

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
    attr_reader :layout_indents
    attr_reader :layout_phase

    def layout_config
      @layout_configs.last || @default_layout_config
    end

    def begin_layout(config)
      @layout_configs.push(config)
    end

    def end_layout(config)
      index = @layout_configs.rindex(config)
      @layout_configs.delete_at(index) if index
    end

    def layout_checkpoint
      [layout_snapshot, @layout_configs.dup]
    end

    def restore_layout(checkpoint)
      snapshot, configs = checkpoint
      restore_layout_snapshot(snapshot)
      @layout_configs.replace(configs)
    end

    def layout_at_indentation
      @layout_phase = :indentation
    end

    def layout_at_content
      @layout_phase = :content
    end

    def layout_content_consumed(atom, source, old_pos)
      @layout_phase = nil if atom.consumes_layout_content? &&
        source.bytepos != old_pos
    end

    def layout_snapshot
      [@layout_indents.dup, @layout_phase]
    end

    def restore_layout_snapshot(snapshot)
      @layout_indents.replace(snapshot.first)
      @layout_phase = snapshot.last
    end
    
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
    # NOTE These methods use #object_id directly, since that seems to bring the
    # most performance benefit. This is a hot spot; going through
    # Atoms::Base#hash doesn't yield as much.
    #
    def lookup(pos, key)
      @cache[pos][key] 
    end
    def set(pos, key, val)
      @cache[pos][key] = val
    end
  end
end
