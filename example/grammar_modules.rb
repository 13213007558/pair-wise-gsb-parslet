# Demonstrates parameterizable grammar modules: a separated-list module is
# instantiated twice in the same parser, each time with a different element
# rule. Both instances use the exact same internal rule names (list, item)
# without interfering with each other -- recursion, captures and dynamic
# rules inside a module instance only ever see that instance's bindings,
# and only exported rules are visible to the parent grammar.
$:.unshift File.dirname(__FILE__) + "/../lib"
require 'parslet'
require 'pp'

class SeparatedList < Parslet::GrammarModule
  # Formal grammar parameters, bound per instance.
  param :element
  param :separator

  rule(:list) { item >> (separator >> item).repeat }
  rule(:item) { element.as(:element) }

  # The interface of the module: only +list+ enters the parent grammar.
  export :list
end

class ListParser < Parslet::Parser
  rule(:integer) { match['0-9'].repeat(1) }
  rule(:word)    { match['a-z'].repeat(1) }

  # Two instances of the same module, with different bindings.
  instance(:int_list, SeparatedList,
    :element => :integer, :separator => proc { str(',').ignore })
  instance(:word_list, SeparatedList,
    :element => :word, :separator => proc { str(';').ignore })

  rule(:top) { int_list.as(:ints) >> str(' ').ignore >> word_list.as(:words) }
  root(:top)
end

pp ListParser.new.parse('1,2,3 a;b;c')

# Error messages keep the original rule names, qualified with the instance
# path (INT_LIST.LIST, WORD_LIST.LIST, ...).
begin
  ListParser.new.parse('1,! a')
rescue Parslet::ParseFailed => failure
  puts failure.parse_failure_cause.ascii_tree
end
