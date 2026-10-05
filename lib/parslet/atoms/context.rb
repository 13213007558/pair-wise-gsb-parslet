module Parslet::Atoms
  # Helper class that implements a transient cache that maps position and
  # parslet object to results. This is used for memoization in the packrat
  # style. 
  #
  # Also, error reporter is stored here and error reporting happens through
  # this class. This makes the reporting pluggable. 
  #
  class Context
    Choice = Struct.new(:id, :committed)

    # @param reporter [#err, #err_at] Error reporter (leave empty for default 
    #   reporter)
    def initialize(reporter=Parslet::ErrorReporter::Tree.new)
      @cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new
      @choices = []
      @next_choice_id = 0
    end

    # Starts the scope of an ordered choice.
    def begin_choice
      Choice.new(@next_choice_id += 1, false).tap do |choice|
        @choices.push(choice)
      end
    end

    # Ends the scope of an ordered choice.
    def end_choice(choice)
      @choices.delete(choice)
    end

    # Returns the depth of the nearest enclosing choice.
    def choice_depth
      @choices.size - 1
    end

    # Runs a block without access to enclosing choice scopes. Lookaheads use
    # this so speculative parsing cannot commit an outer ordered choice.
    def without_choices
      choices = @choices
      @choices = []
      yield
    ensure
      @choices = choices
    end

    # Commits the nearest enclosing ordered choice. A cut outside every
    # ordered choice succeeds but has no choice to commit.
    def cut
      choice = @choices.last
      choice.committed = true if choice
    end

    # Returns the depth of the nearest committed choice, if any.
    def committed_depth
      choice = committed_choice
      choice ? @choices.index(choice) : nil
    end

    # Returns the nearest committed choice, if any.
    def committed_choice
      @choices.reverse_each.detect(&:committed)
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
      choice_path = @choices.map(&:id)
        
      # Not in cache yet? Return early.
      unless entry = lookup(obj, beg, choice_path)
        result = obj.try(source, self, consume_all)
    
        if obj.cached?
          set(obj, beg, choice_path, [result, source.bytepos-beg])
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
    # NOTE These methods use #object_id directly, since that seems to bring the
    # most performance benefit. This is a hot spot; going through
    # Atoms::Base#hash doesn't yield as much.
    #
    def lookup(obj, pos, choice_path)
      @cache[pos][[obj.object_id, choice_path]]
    end
    def set(obj, pos, choice_path, val)
      @cache[pos][[obj.object_id, choice_path]] = val
    end
  end
end
