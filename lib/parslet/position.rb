
# Encapsules the concept of a position inside a string. 
#
class Parslet::Position
  def self.char(charpos, bytepos=charpos)
    allocate.tap do |position|
      position.send(:initialize_char, charpos, bytepos)
    end
  end

  attr_reader :bytepos

  include Comparable

  def initialize(string, bytepos=nil)
    if bytepos
      @string = string
      @bytepos = bytepos
    else
      @charpos = string
    end
  end

  def charpos
    return @charpos unless @charpos.nil?
    @string.byteslice(0, @bytepos).size
  end

private

  def initialize_char(charpos, bytepos)
    @charpos = charpos
    @bytepos = bytepos
  end

  def <=> b
    self.bytepos <=> b.bytepos
  end
end
