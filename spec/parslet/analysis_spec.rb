require 'spec_helper'

describe Parslet::Analysis do
  def check(atom, summaries: {})
    Parslet::Analysis.check(atom, summaries: summaries)
  end

  def build_parser(&class_body)
    Class.new(Parslet::Parser, &class_body).new
  end

  describe 'empty repetition bodies' do
    it "flags str('').repeat" do
      report = check(Parslet.str('').repeat)

      expect(report).not_to be_ok
      expect(report.errors.size).to eq(1)
      expect(report.errors.first.kind).to eq(:empty_repetition)
    end

    it 'flags an alternative with an empty branch' do
      report = check((Parslet.str('a') | Parslet.str('')).repeat)

      expect(report).not_to be_ok
    end

    it 'flags a maybe inside a repeat' do
      report = check(Parslet.str('a').maybe.repeat)

      expect(report).not_to be_ok
    end

    it 'flags a lookahead inside a repeat' do
      report = check(Parslet.str('a').present?.repeat)

      expect(report).not_to be_ok
    end

    it 'accepts a consuming repetition body' do
      expect(check(Parslet.str('a').repeat)).to be_ok
    end

    it 'accepts bounded repetition of an empty body' do
      expect(check(Parslet.str('').repeat(0, 2))).to be_ok
    end

    it 'accepts normal nullable branches' do
      expect(check(Parslet.str('a').maybe >> Parslet.str('b'))).to be_ok
      expect(check(Parslet.str('a') | Parslet.str(''))).to be_ok
    end
  end

  describe 'left recursion' do
    it 'flags direct left recursion' do
      report = check(build_parser {
        rule(:a) { a >> str('b') | str('c') }
        root(:a)
      })

      expect(report).not_to be_ok
      finding = report.errors.first
      expect(finding.kind).to eq(:left_recursion)
      expect(finding.chain).to eq([:a, :a])
    end

    it 'flags mutual recursion without progress' do
      report = check(build_parser {
        rule(:a) { b >> str('x') }
        rule(:b) { a | str('y') }
        root(:a)
      })

      expect(report).not_to be_ok
      finding = report.errors.first
      expect(finding.kind).to eq(:left_recursion)
      expect(finding.chain).to eq([:a, :b, :a])
    end

    it 'flags recursion hidden behind a nullable prefix' do
      report = check(build_parser {
        rule(:a) { str('x').maybe >> a | str('y') }
        root(:a)
      })

      expect(report).not_to be_ok
      expect(report.errors.first.kind).to eq(:left_recursion)
    end

    it 'accepts recursion that consumes input first' do
      report = check(build_parser {
        rule(:a) { str('(') >> a >> str(')') | str('x') }
        root(:a)
      })

      expect(report).to be_ok
    end

    it 'accepts right recursion' do
      report = check(build_parser {
        rule(:a) { str('x') >> a | str('y') }
        root(:a)
      })

      expect(report).to be_ok
    end
  end

  describe 'dynamic atoms' do
    let(:atom) { Parslet.dynamic { Parslet.str('a') }.repeat }

    it 'marks unsummarised dynamic atoms as unknown, not as errors' do
      report = check(atom)

      expect(report).to be_ok
      expect(report.unknowns.size).to eq(1)
      expect(report.unknowns.first.kind).to eq(:empty_repetition)
    end

    it 'never evaluates the dynamic block' do
      report = check(Parslet.dynamic { raise 'must not be called' }.repeat)

      expect(report.unknowns.size).to eq(1)
    end

    it 'accepts a summary stating the atom consumes input' do
      report = check(atom, summaries: { dynamic: { nullable: false } })

      expect(report).to be_ok
      expect(report.findings).to be_empty
    end

    it 'turns a summary stating the atom can be empty into an error' do
      report = check(atom, summaries: { dynamic: { nullable: true } })

      expect(report).not_to be_ok
    end

    it 'resolves named atoms by name' do
      named = (Parslet.dynamic { Parslet.str('a') }).as(:thing).repeat

      expect(check(named, summaries: { thing: { nullable: false } }))
        .to be_ok
      expect(check(named).unknowns.size).to eq(1)
    end

    it 'marks recursion through a dynamic prefix as unknown' do
      parser = build_parser {
        rule(:a) { dynamic { str('x') } >> a | str('y') }
        root(:a)
      }

      report = check(parser)
      expect(report).to be_ok
      expect(report.unknowns.map(&:kind)).to include(:left_recursion)

      summarised = check(parser, summaries: { dynamic: { nullable: false } })
      expect(summarised.findings).to be_empty
    end
  end

  describe 'rule chains' do
    it 'reports the chain of rules from the entry to the risk' do
      report = check(build_parser {
        rule(:file) { line.repeat }
        rule(:line) { str('').repeat >> str('x') }
        root(:file)
      })

      expect(report.errors.size).to eq(1)
      finding = report.errors.first
      expect(finding.chain).to eq([:file, :line])
      expect(finding.to_s).to include('file -> line')
    end

    it 'follows rule references through named and sequence atoms' do
      report = check(build_parser {
        rule(:file) { str('h') >> body.as(:b) }
        rule(:body) { str('').repeat }
        root(:file)
      })

      expect(report.errors.first.chain).to eq([:file, :body])
    end
  end

  describe 'infix expressions' do
    it 'accepts consuming elements and operators' do
      atom = Parslet.infix_expression(
        Parslet.str('a'), [Parslet.str('+'), 1, :left])

      expect(check(atom)).to be_ok
    end

    it 'flags empty element combined with empty operator' do
      atom = Parslet.infix_expression(
        Parslet.str('a').maybe, [Parslet.str('+').maybe, 1, :left])

      report = check(atom)
      expect(report).not_to be_ok
      expect(report.errors.first.kind).to eq(:empty_infix)
    end
  end

  describe Parslet::Analysis::Report do
    it 'renders findings as text' do
      report = check(Parslet.str('').repeat)

      expect(report.to_s).to include('empty_repetition')
      expect(report.to_s).to include('1 error(s)')
    end

    it 'renders a clean bill of health' do
      expect(check(Parslet.str('a')).to_s).to include('no issues')
    end
  end
end
