class Parslet::ParseOutcome
  attr_reader :status, :value

  def initialize(status, value=nil)
    @status = status
    @value = value
  end
end
