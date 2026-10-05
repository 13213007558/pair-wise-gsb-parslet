require 'parslet/streaming_source'

module Parslet
  # An incremental parse session: input is fed to the parser chunk by
  # chunk, and the parser decides after every chunk whether it has
  # succeeded, has definitely failed, or needs more input.
  #
  #   session = Parslet::Session.new(parser)   # or: parser.session
  #   session.feed('{"key":')   # => :waiting
  #   session.feed(' 1}')       # => :waiting
  #   session.finish            # => :success
  #   session.result            # => {:key => '1'@7}
  #
  # The session is in exactly one of three states, reported by #state (and
  # the predicates #waiting?, #success?, #failure?):
  #
  # [:waiting] More input is needed to decide the parse. Nothing is
  #            committed yet: ordered choices stay open, so in
  #            <code>str('ab') | str('a')</code> a lone 'a' does not
  #            commit to the short branch while 'b' might still arrive.
  # [:success] The parse consumed all input and the input was finished
  #            with #finish. #result holds the parse result (the same
  #            value a regular #parse call would return).
  # [:failure] The parse cannot succeed anymore, no matter what input
  #            would follow. #error holds the failure (a
  #            Parslet::ParseFailed).
  #
  # Only #finish signals end of input; as long as the stream is open, the
  # parser waits instead of failing on premature input end. This works
  # across ordered choice, lookahead, repetition and multi-byte characters
  # that are split over chunk boundaries.
  #
  # The parse itself is incremental: it is suspended exactly where it ran
  # out of input and resumed when more input arrives, so feeding a byte
  # never re-parses the input that came before it. Input that the parser
  # can provably never backtrack to is released (see #retained_bytes);
  # slices and captures handed out so far stay fully usable.
  #
  # Note: custom atoms that rewind the source to arbitrary positions and
  # Parslet::Accelerator are not compatible with input release. Pass
  # <code>release: false</code> to keep all input in memory.
  #
  class Session
    # Raised when input is fed to a session that already completed.
    #
    class FinishedError < StandardError; end

    # Current state of the session: :waiting, :success or :failure.
    attr_reader :state

    # Creates a parse session for the given atom (a Parslet::Parser
    # instance or any other parslet atom).
    #
    # @param atom [Parslet::Atoms::Base] parser or atom to run
    # @option options [Parslet::ErrorReporter] :reporter error reporter to
    #   use, defaults to Parslet::ErrorReporter::Tree
    # @option options [Encoding] :encoding encoding of the fed input,
    #   defaults to UTF-8
    # @option options [Boolean] :release (true) release input the parse
    #   can never backtrack to
    #
    def initialize(atom, options={})
      @atom = atom
      reporter = options[:reporter] || Parslet::ErrorReporter::Tree.new

      @source = Parslet::StreamingSource.new(
        options[:encoding] || Encoding::UTF_8)
      @context = Parslet::Atoms::Context.new(reporter)
      @context.track_frames!

      @release = options.fetch(:release, true)
      @source.release_handler = -> { release_input } if @release

      @state = :waiting
      @result = nil
      @error = nil

      @fiber = Fiber.new { run }
    end

    # Feeds a chunk of input to the parser. Returns the session state
    # after the chunk has been processed (:waiting, :success or
    # :failure).
    #
    def feed(chunk)
      ensure_running!
      @source.feed(chunk)
      pump
      @state
    end

    # Signals end of input and runs the parse to its conclusion. Returns
    # the final state (:success or :failure).
    #
    def finish
      ensure_running!
      @source.finish!
      pump
      @state
    end

    def waiting?
      @state == :waiting
    end

    def success?
      @state == :success
    end

    def failure?
      @state == :failure
    end

    # The parse result, once the session is in :success state. Identical
    # to what Parslet::Atoms::Base#parse would have returned for the same
    # input. Nil in all other states.
    #
    attr_reader :result

    # The parse failure (a Parslet::ParseFailed), once the session is in
    # :failure state. Nil in all other states.
    #
    attr_reader :error

    # Absolute byte offset of the position the parser is currently at
    # (where it paused when waiting for more input).
    #
    def position
      @source.bytepos
    end

    # Number of input bytes the session currently retains. Input that the
    # parser can never backtrack to is released and no longer counted
    # here.
    #
    def retained_bytes
      @source.retained_bytes
    end

  private

    def ensure_running!
      raise FinishedError,
        "this parse session is already #{@state}" if @state != :waiting
    end

    def pump
      outcome = @fiber.resume

      if @fiber.alive?
        # Suspended, waiting for more input: a good moment to drop input
        # the parse can never return to.
        release_input if @release
      else
        success, value = outcome
        if success
          @state = :success
          @result = @atom.flatten(value)
        else
          @state = :failure
          @error = to_exception(value)
        end
      end
    rescue Exception => exception
      @state = :failure
      @error = exception
      raise
    end

    # The parse proper, run inside a fiber so it can suspend wherever it
    # needs more input than is currently available.
    #
    def run
      success, value = @atom.apply(@source, @context, true)

      # A match that completes before the input is finished is not final
      # yet: more input could still arrive that the grammar would not
      # know what to do with.
      if success && !@source.eof?
        @source.wait_for_input?(1)

        if @source.chars_left > 0
          offending_pos   = @source.pos
          offending_input = @source.consume(10)

          return @context.err_at(
            @atom,
            @source,
            "Don't know what to do with #{offending_input.to_s.inspect}",
            offending_pos)
        end
      end

      [success, value]
    end

    # Releases all input the suspended parse can provably never read
    # again: the minimum of the rewind positions of the currently live
    # parse frames and the current read position.
    #
    def release_input
      horizon = @context.rewind_horizon
      head = @source.bytepos
      horizon = horizon ? [horizon, head].min : head
      return if horizon <= 0

      @source.release_before(horizon)
      @context.prune_before(horizon)
    end

    def to_exception(cause)
      cause.raise
    rescue Parslet::ParseFailed => exception
      exception
    end
  end
end
