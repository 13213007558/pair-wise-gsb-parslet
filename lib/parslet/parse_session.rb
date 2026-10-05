class Parslet::ParseSession
  attr_reader :source

  def initialize(parser, reporter=nil)
    @parser = parser
    @reporter = reporter || Parslet::ErrorReporter::Tree.new
    @source = Parslet::Source.new('', finished: false)
    @context = Parslet::Atoms::Context.new(@reporter)
    @source.on_release { |position| @context.release_before(position) }
    @status = :waiting
    @result = nil
    @failure = nil
    @fiber = Fiber.new { run }
    resume
  end

  def feed(chunk)
    append_and_resume(chunk)
  end

  alias append feed
  alias << feed

  def finish
    if waiting?
      @source.finish
      begin
        resume
      rescue StandardError => error
        @failure = error
        @status = :failure
        raise
      end
    end

    @status
  end

  def waiting?
    @status == :waiting
  end

  def success?
    @status == :success
  end

  def failure?
    @status == :failure
  end

  def value
    @result
  end

  alias result value

  def error
    @failure
  end

  def failure
    @failure
  end

  def status
    @status
  end

  def retained_bytesize
    [@source.bytesize - @source.base_bytepos, 0].max
  end

  alias retained_bytes retained_bytesize

  def pause_pos
    @source.pause_pos
  end

  alias pause_bytepos pause_pos

private

  def append_and_resume(chunk)
    if failure?
      raise @failure || ArgumentError, 'Cannot feed a failed parse session.'
    end
    raise ArgumentError, 'Cannot feed a finished parse session.' unless waiting?

    @source.append(chunk)
    resume
    @status
  end

  def run
    success, value = @parser.apply(@source, @context, true)

    if success
      value = @parser.flatten(value)
      Fiber.yield(Parslet::ParseOutcome.new(:success, value))
    else
      exception = begin
        value.raise
      rescue Parslet::ParseFailed => failure
        failure
      end
      Fiber.yield(Parslet::ParseOutcome.new(:failure, exception))
    end
  end

  def resume
    outcome = @fiber.resume

    case outcome
    when nil
      @status = :waiting
      release_input
    when Parslet::ParseOutcome
      @status = outcome.status

      if outcome.status == :success
        @result = outcome.value
        @source.release_before(@source.bytesize)
      else
        @failure = outcome.value
      end
    end
  end

  def release_input
    @source.release_before(@source.pause_commit_pos)
  end
end
