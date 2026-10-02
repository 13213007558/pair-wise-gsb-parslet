
# The base class for all your parsers. Use as follows: 
#
#   require 'parslet'
#        
#   class MyParser < Parslet::Parser
#     rule(:a) { str('a').repeat }
#     root(:a)        
#   end
#        
#   pp MyParser.new.parse('aaaa')   # => 'aaaa'
#   pp MyParser.new.parse('bbbb')   # => Parslet::Atoms::ParseFailed: 
#                                   #    Don't know what to do with bbbb at line 1 char 1.
#
# Parslet::Parser is also a grammar atom. This means that you can mix full 
# fledged parsers freely with small parts of a different parser. 
#
# Example: 
#   class ParserA < Parslet::Parser
#     root :aaa
#     rule(:aaa) { str('a').repeat(3,3) }
#   end
#   class ParserB < Parslet::Parser
#     root :expression
#     rule(:expression) { str('b') >> ParserA.new >> str('b') }
#   end
#
# In the above example, ParserB would parse something like 'baaab'. 
#
class Parslet::Parser < Parslet::Atoms::Base
  include Parslet

  class << self # class methods
    # Define the parsers #root function. This is the place where you start 
    # parsing; if you have a rule for 'file' that describes what should be 
    # in a file, this would be your root declaration: 
    #
    #   class Parser
    #     root :file
    #     rule(:file) { ... }
    #   end
    #
    # #root declares a 'parse' function that works just like the parse 
    # function that you can call on a simple parslet, taking a string as input
    # and producing parse output. 
    #
    # In a way, #root is a shorthand for: 
    #
    #   def parse(str)
    #     your_parser_root.parse(str)
    #   end
    #
    def root(name)
      undef_method :root if method_defined? :root
      define_method(:root) do
        self.send(name)
      end
    end

    # Configures the layout (indentation) policy for this parser. This is
    # the central place that decides how tab characters in indentation are
    # treated; see Parslet::Layout::Policy for the available options.
    #
    # Example:
    #
    #   class MyParser < Parslet::Parser
    #     layout tab: :expand, tab_width: 4
    #   end
    #
    def layout(options)
      # Validate eagerly, so that a misspelled policy fails fast.
      Parslet::Layout::Policy.build(options)
      @layout_options = options
    end

    # The layout options configured with .layout, inherited from superclass
    # parsers unless overridden. 
    #
    def layout_options
      return @layout_options if instance_variable_defined?(:@layout_options)
      superclass.respond_to?(:layout_options) ?
        superclass.layout_options :
        nil
    end
  end

  # Creates the context to parse within. The context carries the layout
  # policy configured through .layout.
  #
  def new_context(error_reporter)
    Parslet::Atoms::Context.new(error_reporter, self.class.layout_options)
  end
  
  def try(source, context, consume_all)
    root.try(source, context, consume_all)
  end
  
  def to_s_inner(prec)
    root.to_s(prec)
  end
end
