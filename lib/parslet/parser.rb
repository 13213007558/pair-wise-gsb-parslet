
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

    # Enables (or disables) support for left recursive rules in this
    # parser. With left recursion enabled, rules may refer to themselves
    # (directly or indirectly through other rules) in leftmost position:
    #
    #   rule(:expr) { expr >> str('+') >> term | term }
    #
    # Such rules are evaluated using a seed-growing algorithm that
    # preserves ordered choice semantics and repeatedly extends the match
    # until no more input can be consumed. Rules that can succeed without
    # consuming input (nullable recursion) raise
    # Parslet::LeftRecursionError.
    #
    # Left recursion can also be enabled per rule:
    #
    #   rule(:expr, left_recursive: true) { ... }
    #
    def left_recursion(enabled=true)
      @left_recursion_enabled = enabled
    end

    # True if left recursion support is enabled for this parser class.
    #
    def left_recursion_enabled?
      if instance_variable_defined?(:@left_recursion_enabled)
        @left_recursion_enabled
      elsif superclass.respond_to?(:left_recursion_enabled?)
        superclass.left_recursion_enabled?
      else
        false
      end
    end
  end
  
  def try(source, context, consume_all)
    # Apply the root rule through the context (instead of calling #try
    # directly) so that the root rule takes part in caching and in the
    # left recursion scheme like any other rule reference.
    root.apply(source, context, consume_all)
  end

  # Creates the parse context, enabling left recursion if the parser
  # class opts into it via .left_recursion.
  #
  def setup_and_apply(source, error_reporter, consume_all)
    context = Parslet::Atoms::Context.new(
      error_reporter, self.class.left_recursion_enabled?)
    apply(source, context, consume_all)
  end
  
  def to_s_inner(prec)
    root.to_s(prec)
  end
end
