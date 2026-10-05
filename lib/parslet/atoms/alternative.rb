
# Alternative during matching. Contains a list of parslets that is tried each
# one in turn. Only fails if all alternatives fail. 
#
# Example: 
# 
#   str('a') | str('b')   # matches either 'a' or 'b'
#
class Parslet::Atoms::Alternative < Parslet::Atoms::Base
  attr_reader :alternatives
  
  # Constructs an Alternative instance using all given parslets in the order
  # given. This is what happens if you call '|' on existing parslets, like 
  # this: 
  #
  #   str('a') | str('b')
  #
  def initialize(*alternatives)
    super()
    
    @alternatives = alternatives
  end

  #---
  # Don't construct a hanging tree of Alternative parslets, instead store them
  # all here. This reduces the number of objects created.
  #+++
  def |(parslet)
    self.class.new(*@alternatives + [parslet])
  end

  def error_msg
    @error_msg ||= "Expected one of #{alternatives.inspect}"
  end

  def try(source, context, consume_all)
    choice = context.begin_choice
    depth = context.choice_depth
    errors = []

    begin
      alternatives.each { |alternative|
        success, value = result =
          alternative.apply(source, context, consume_all)
        if success
          return result
        end

        raise Parslet::CutTaken.new(depth, value) if choice.committed
        errors << value
      }
    rescue Parslet::CutTaken => exception
      raise unless exception.depth == depth
      choice.committed = false
      return [false, mark_cut(exception.cause)]
    ensure
      context.end_choice(choice)
    end
    
    # If we reach this point, all alternatives have failed. 
    if choice.committed
      return [false, mark_cut(deepest_cause(errors))]
    end
    committed_errors = errors.compact.select { |error| error.respond_to?(:cut?) && error.cut? }
    return [false, deepest_cause(committed_errors)] unless committed_errors.empty?

    context.err(self, source, error_msg, errors)
  end

  def mark_cut(cause)
    return cause if cause.nil?
    cause.cut = true
    cause
  end
  private :mark_cut

  def deepest_cause(causes)
    causes = Array(causes).flatten.compact
    return nil if causes.empty?
    deepest = causes.max_by(&:pos)
    deepest.children.empty? ? deepest : deepest_cause(deepest.children)
  end
  private :deepest_cause

  precedence ALTERNATE
  def to_s_inner(prec)
    alternatives.map { |a| a.to_s(prec) }.join(' / ')
  end
end
