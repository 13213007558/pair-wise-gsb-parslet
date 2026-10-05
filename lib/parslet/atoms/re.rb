# Matches a special kind of regular expression that only ever matches one
# character at a time. Useful members of this family are: <code>character
# ranges, \\w, \\d, \\r, \\n, ...</code>
#
# Example: 
#
#   match('[a-z]')  # matches a-z
#   match('\s')     # like regexps: matches space characters
#
class Parslet::Atoms::Re < Parslet::Atoms::Base
  attr_reader :match, :re
  def initialize(match)
    super()

    @match = match.to_s
    @re    = Regexp.new(self.match, Regexp::MULTILINE)
  end

  def error_msgs
    @error_msgs ||= {
      premature: 'Premature end of input',
      failed: "Failed to match #{match.inspect[1..-2]}"
    }
  end

  def try(source, context, consume_all)
    loop do
      return succ(source.consume(1)) if source.matches?(@re)
      if source.chars_left < 1
        if !source.finished? && (source.bytes_left == 0 || source.pending_character?)
          source.wait_at(source.bytepos, source.rollback_positions.empty?)
          next
        end
        return context.err(self, source, error_msgs[:premature])
      else
        return context.err(self, source, error_msgs[:failed])
      end
    end
  end

  def to_s_inner(prec)
    match.inspect[1..-2]
  end
end
