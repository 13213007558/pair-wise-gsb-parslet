
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
    errors = []
    alternatives.each do |a|
      # Each branch gets its own cut scope: A cut fired inside this branch
      # commits only this alternation, never an outer one.
      context.push_cut_barrier
      success, value = result = a.apply(source, context, consume_all)
      committed = context.pop_cut_barrier

      return result if success

      # A cut was fired in this branch: The alternation is committed and
      # fails right here, propagating the branchs error (and its real
      # failure position) instead of trying the remaining alternatives.
      return result if committed

      # Aggregate all errors
      errors << value
    end
    
    # If we reach this point, all alternatives have failed. 
    context.err(self, source, error_msg, errors)
  end

  precedence ALTERNATE
  def to_s_inner(prec)
    alternatives.map { |a| a.to_s(prec) }.join(' / ')
  end
end
