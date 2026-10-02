require 'spec_helper'
require 'parslet/lint'

describe Parslet::Lint do
  SummarizedDynamicAtom = Parslet.dynamic { str('x') }
  RecursionSummaryDynamicAtom = Parslet.dynamic { str('x') }

  RecursiveLintGrammar = Class.new(Parslet::Parser) do
    root(:inside)
    rule(:inside) { inside }
  end

  def lint(grammar, summaries={})
    described_class.analyze(grammar, summaries)
  end

  it 'detects a literal repetition body that can succeed without consuming input' do
    grammar = Class.new(Parslet::Parser) do
      root(:empty)
      rule(:empty) { str('').repeat }
    end

    result = lint(grammar.new)

    expect(result).not_to be_ok
    expect(result.errors.size).to eq(1)
    expect(result.errors.first.kind).to eq(:empty_repetition)
    expect(result.errors.first.chain).to eq([:empty])
  end

  it 'detects a nullable repetition body reached through another rule' do
    grammar = Class.new(Parslet::Parser) do
      root(:list)
      rule(:list) { gap.repeat }
      rule(:gap) { str('').maybe }
    end

    result = lint(grammar.new)

    expect(result.errors.map(&:kind)).to eq([:empty_repetition])
    expect(result.errors.first.chain).to eq([:list, :gap])
  end

  it 'allows ordinary nullable branches and bounded optionals' do
    grammar = Class.new(Parslet::Parser) do
      root(:word)
      rule(:word) { str('a').repeat >> str('b').maybe }
    end

    expect(lint(grammar.new)).to be_ok
  end

  it 'allows an empty string outside an unbounded repetition' do
    grammar = Class.new(Parslet::Parser) do
      root(:word)
      rule(:word) { str('') >> str('a').maybe }
    end

    expect(lint(grammar.new)).to be_ok
  end

  it 'detects direct left recursion with no progress' do
    grammar = Class.new(Parslet::Parser) do
      root(:expression)
      rule(:expression) { expression | str('a') }
    end

    result = lint(grammar.new)

    expect(result.errors.map(&:kind)).to eq([:nonprogress_recursion])
    expect(result.errors.first.chain).to eq([:expression, :expression])
  end

  it 'detects an indirect recursive path with no progress' do
    grammar = Class.new(Parslet::Parser) do
      root(:a)
      rule(:a) { b }
      rule(:b) { a }
    end

    result = lint(grammar.new)

    expect(result.errors.map(&:kind)).to eq([:nonprogress_recursion])
    expect(result.errors.first.chain).to eq([:a, :b, :a])
  end

  it 'does not report recursion after a consuming prefix' do
    grammar = Class.new(Parslet::Parser) do
      root(:a)
      rule(:a) { str('(') >> a | str('x') }
    end

    expect(lint(grammar.new)).to be_ok
  end

  it 'detects non-progress recursion inside a rule reached after input is consumed' do
    grammar = Class.new(Parslet::Parser) do
      root(:a)
      rule(:a) { str('(') >> b | str('x') }
      rule(:b) { b }
    end

    result = lint(grammar.new)

    expect(result.errors.map(&:kind)).to eq([:nonprogress_recursion])
    expect(result.errors.first.chain).to eq([:a, :b, :b])
  end

  it 'detects non-progress recursion inside an embedded parser boundary' do
    outer = Class.new(Parslet::Parser) do
      root(:outside)
      rule(:outside) { str('(') >> RecursiveLintGrammar.new }
    end

    result = lint(outer.new)

    expect(result.errors.map(&:kind)).to eq([:nonprogress_recursion])
    expect(result.errors.first.chain).to eq([:outside, :inside, :inside])
  end

  it 'does not report recursion only reachable after an always-successful ordered alternative' do
    grammar = Class.new(Parslet::Parser) do
      root(:a)
      rule(:a) { str('') | a }
    end

    expect(lint(grammar.new)).to be_ok
  end

  it 'reports unknown dynamic repetition bodies as warnings' do
    atom = Parslet.dynamic { str('') }
    grammar = atom.repeat

    result = lint(grammar)

    expect(result).to be_ok
    expect(result.warnings.map(&:kind)).to eq([:unknown_repetition])
    expect(result.warnings.first.blockers).to eq([atom])
  end

  it 'does not treat a hash summary provider itself as an executable summary' do
    atom = Parslet.dynamic { str('') }

    result = lint(atom.repeat, {})

    expect(result.warnings.map(&:kind)).to eq([:unknown_repetition])
  end

  it 'uses author-provided dynamic summaries to suppress false positives' do
    atom = Parslet.dynamic { str('x') }
    grammar = atom.repeat

    result = lint(grammar, atom => { nullable: false, consuming: true, failable: true })

    expect(result).to be_ok
    expect(result.findings).to be_empty
  end

  it 'accepts a proc as a dynamic summary provider' do
    atom = Parslet.dynamic { str('x') }
    grammar = atom.repeat
    summaries = lambda do |dynamic|
      next unless dynamic.equal?(atom)
      { nullable: false, consuming: true }
    end

    expect(lint(grammar, summaries).findings).to be_empty
  end

  it 'uses rules named in a dynamic summary for recursive analysis' do
    grammar = Class.new(Parslet::Parser) do
      root(:list)
      rule(:list) { SummarizedDynamicAtom.repeat }
      rule(:b) { str('b') }
    end
    summaries = {
      SummarizedDynamicAtom => {
        nullable: false,
        consuming: true,
        failable: true,
        rules: [:b]
      }
    }

    result = lint(grammar.new, summaries)

    expect(result.findings).to be_empty
  end

  it 'reports recursion through a named dynamic reference' do
    grammar = Class.new(Parslet::Parser) do
      root(:a)
      rule(:a) { RecursionSummaryDynamicAtom }
      rule(:dynamic_target) { dynamic_target }
    end
    summary = {
      nullable: true,
      consuming: false,
      failable: false,
      rules: [:dynamic_target]
    }

    result = lint(grammar.new, RecursionSummaryDynamicAtom => summary)

    expect(result.errors.map(&:kind)).to eq([:nonprogress_recursion])
    expect(result.errors.first.chain).to eq([:a, :dynamic_target, :dynamic_target])
  end

  it 'marks dynamic recursive paths as possible rather than certain problems' do
    grammar = Class.new(Parslet::Parser) do
      root(:a)
      rule(:a) { dynamic { a } }
    end

    result = lint(grammar.new)

    expect(result).to be_ok
    expect(result.warnings.map(&:kind)).to eq([:unknown_recursion])
  end

  it 'exposes the check through a parser instance' do
    grammar = Class.new(Parslet::Parser) do
      root(:a)
      rule(:a) { str('a').repeat }
    end

    expect(grammar.new.lint).to be_ok
  end
end
