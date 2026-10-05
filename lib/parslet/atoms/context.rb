module Parslet::Atoms
  # Helper class that implements a transient cache that maps position and
  # parslet object to results. This is used for memoization in the packrat
  # style. 
  #
  # Also, error reporter is stored here and error reporting happens through
  # this class. This makes the reporting pluggable. 
  #
  class Context
    ChoiceFrame = Struct.new(:atom, :committed) do
      def initialize(atom)
        super(atom, false)
      end
    end

    # @param reporter [#err, #err_at] Error reporter (leave empty for default 
    #   reporter)
    def initialize(reporter=Parslet::ErrorReporter::Tree.new)
      @cache = Hash.new { |h, k| h[k] = {} }
      @reporter = reporter
      @captures = Parslet::Scope.new
      @choice_frames = []
    end

    def begin_choice(atom)
      frame = ChoiceFrame.new(atom)
      @choice_frames.push(frame)
      frame
    end

    def end_choice
      @choice_frames.pop
    end

    def commit!
      frame = @choice_frames.last
      raise Parslet::ParseFailed, 'cut called outside of an ordered choice' \
        unless frame
      frame.committed = true
      frame
    end

    def committed?(cause)
      cause.respond_to?(:committed?) && cause.committed?
    end

    def committed_to_active_choice?(cause)
      frame = committed_frame
      frame && cause.respond_to?(:committed_for?) &&
        cause.committed_for?(frame)
    end

    def committed_frame
      @choice_frames.reverse.find(&:committed)
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
      frames_before = @choice_frames.dup
        
      # Not in cache yet? Return early.
      unless entry = lookup(obj, beg)
        result = obj.try(source, self, consume_all)
    
        if obj.cached?
          cut_depth = commitment_depth(frames_before)
          set obj, beg, [result, source.bytepos-beg, cut_depth,
                         internal_commitment?(frames_before.size)]
        end
        
        return result
      end

      # the condition in unless has returned true, so entry is not nil.
      result, advance, cut_depth, internal_commitment = entry

      replay_commitment(
        result, frames_before.size, cut_depth, internal_commitment)

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
      if @reporter
        cause = @reporter.err_at(*args)
        mark_committed(cause)
        return [false, cause]
      end
      return [false, nil]
    end
    
    # Report an error. 
    # @see ErrorReporter
    #
    def err(*args)
      if @reporter
        cause = @reporter.err(*args)
        mark_committed(cause)
        return [false, cause]
      end
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
    def mark_committed(cause)
      frame = committed_frame
      cause.commit!(frame) if frame && cause.respond_to?(:commit!)
    end

    def commitment_depth(frames_before)
      frames_before.reverse_each.with_index do |frame, index|
        return frames_before.size - index - 1 if frame.committed
      end
      nil
    end

    def internal_commitment?(frame_count)
      @choice_frames.size > frame_count
    end

    def replay_commitment(result, frame_count, cut_depth, internal_commitment)
      success, cause = result
      frame = cut_depth && @choice_frames[cut_depth]

      if frame
        frame.committed = true
        cause.commit!(frame) if !success && cause
      elsif !success && frame_count == @choice_frames.size &&
          !internal_commitment && cause
        cause.clear_commitment!
      end
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
