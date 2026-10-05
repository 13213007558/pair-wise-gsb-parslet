class Parslet::Transform
  # Outcome of one composable rewrite attempt. The status is one of
  # +:no_match+, +:unchanged+, +:changed+, +:error+, +:cycle+, or
  # +:budget_exhausted+.
  Result = Struct.new(:status, :value, :exception, :iterations, :witness, keyword_init: true) do
    TERMINAL_STATUSES = [:cycle, :budget_exhausted].freeze

    def matched?
      !no_match?
    end

    def success?
      changed? || unchanged?
    end

    def no_match?
      status == :no_match
    end

    def unchanged?
      status == :unchanged
    end

    def changed?
      status == :changed
    end

    def error?
      status == :error
    end

    def cycle?
      status == :cycle
    end

    def budget_exhausted?
      status == :budget_exhausted
    end

    def terminal?
      TERMINAL_STATUSES.include?(status)
    end

    def value!
      raise exception if error?
      value
    end

    def self.no_match(value)
      new(status: :no_match, value: value)
    end

    def self.match(original, value)
      new(status: original == value ? :unchanged : :changed, value: value)
    end

    def self.unchanged(value)
      new(status: :unchanged, value: value)
    end

    def self.error(original, exception, iterations=nil)
      new(
        status: :error,
        value: original,
        exception: exception,
        iterations: iterations
      )
    end

    def self.cycle(value, iterations, witness)
      new(status: :cycle, value: value, iterations: iterations, witness: witness)
    end

    def self.budget_exhausted(value, iterations)
      new(status: :budget_exhausted, value: value, iterations: iterations)
    end
  end

  # Evidence for a repeated state. +states+ contains states before the repeat;
  # +repeat_from+ is the index of the first equivalent state.
  CycleWitness = Struct.new(:states, :repeat_from, :iteration, keyword_init: true)
end
