require 'spec_helper'

describe Parslet::Session do
  # A small grammar for comma separated words and numbers; exercises
  # sequences, alternatives, repetition and named results.
  class SessionListParser < Parslet::Parser
    rule(:word)   { match['a-z'].repeat(1).as(:word) }
    rule(:number) { match['0-9'].repeat(1).as(:number) }
    rule(:item)   { word | number }
    rule(:list)   { item >> (str(',') >> item).repeat }
    root(:list)
  end

 # A grammar whose parse only consumes 'a', but looks ahead at 'b'. The
 # lookahead read must be part of the cache entry's read range.
 class SessionLookaheadParser < Parslet::Parser
    rule(:main) { (str('a') >> str('b').present?).as(:p) >> any }
    root(:main)
  end

  # Counter-example grammar: on "ab", the str('abc') branch fails because
  # the input ends early. That failed branch has read (the length of) the
  # input, so appending must invalidate it.
  class SessionPrematureParser < Parslet::Parser
    rule(:main) { str('abc') | str('ab') }
    root(:main)
  end

  # Counter-example grammar: on "bc", the str('bx') branch fails after
  # reading the 'c' at position 1. A cache that only tracks successfully
  # consumed input would keep the str('b') result when position 1 changes.
  class SessionFailedBranchParser < Parslet::Parser
    rule(:main) { (str('bx') | str('b')).as(:w) >> any.maybe }
    root(:main)
  end

  # Grammar with a capture and a dynamic rule depending on it.
  class SessionTagParser < Parslet::Parser
    rule(:name)   { match['a-z'].repeat(1) }
    rule(:header) { str('#') >> name.capture(:tag) >> str('#') }
    rule(:body)   { dynamic { |src, ctx| str(ctx.captures[:tag].to_s) } }
    rule(:tail)   { match['a-z'].repeat(1).as(:tail) }
    rule(:doc)    { header >> body >> str('!') >> tail }
    root(:doc)
  end

  # Line based grammar to exercise line/column information of slices.
  class SessionLinesParser < Parslet::Parser
    rule(:line)  { match["^\n"].repeat(1).as(:line) >> str("\n") }
    rule(:lines) { line.repeat }
    root(:lines)
  end

  # Word list grammar that also matches multibyte characters.
  class SessionUtf8Parser < Parslet::Parser
    rule(:word) { match['[^,]'].repeat(1).as(:word) }
    rule(:list) { word >> (str(',') >> word).repeat }
    root(:list)
  end

  # Deeply compares two parse results, including slice offsets and
  # line/column information. Plain == on slices only compares string
  # content, which would not catch stale positions.
  def tree_signature(node)
    case node
    when Parslet::Slice
      [:slice, node.str, node.offset, node.line_and_column]
    when Array
      node.map { |element| tree_signature(element) }
    when Hash
      node.map { |key, value| [key, tree_signature(value)] }
    else
      node
    end
  end

  def apply_edit(text, start, delete_count, replacement)
    text[0...start] + replacement + (text[(start + delete_count)..-1] || '')
  end

  # Parses text, applies each edit ([start, delete_count, replacement] in
  # coordinates of the text before the edit) and checks after every single
  # edit that the session result is identical to a full reparse of the new
  # text - including all slice positions. Returns the session.
  def expect_edits_to_match_full_reparse(parser, text, edits)
    session = described_class.new(parser)
    current = text

    expect(
      tree_signature(session.parse(current))).to eq(
      tree_signature(parser.parse(current)))

    edits.each do |(start, delete_count, replacement)|
      current = apply_edit(current, start, delete_count, replacement)

      expected = parser.parse(current)
      actual = session.edit(start, delete_count, replacement)

      expect(session.text).to eq(current)
      expect(
        tree_signature(actual)).to eq(
        tree_signature(expected))
    end

    session
  end

  describe '#parse' do
    let(:session) { described_class.new(SessionListParser.new) }

    it 'returns the same result as a plain parse' do
      expect(session.parse('aaa,bbb,12')).to eq(
        SessionListParser.new.parse('aaa,bbb,12'))
    end

    it 'reports the whole input as the (re)parsed range' do
      session.parse('aaa,bbb')
      expect(session.reparse_range).to eq(0...7)
    end
  end

  describe '#edit' do
    it 'requires a call to #parse first' do
      expect {
        described_class.new(SessionListParser.new).edit(0, 0, 'x')
      }.to raise_error(RuntimeError, /parse/)
    end

    it 'rejects edits outside the current text' do
      session = described_class.new(SessionListParser.new)
      session.parse('abc')
      expect { session.edit(5, 0, 'x') }.to raise_error(ArgumentError)
      expect { session.edit(0, 9, 'x') }.to raise_error(ArgumentError)
      expect { session.edit(-1, 0, 'x') }.to raise_error(ArgumentError)
    end
  end

  context 'with a list grammar' do
    let(:parser) { SessionListParser.new }

    it 'tracks a full reparse over a chain of inserts, deletes and replaces' do
      expect_edits_to_match_full_reparse(parser, 'aaa,bbb,ccc', [
        [8, 3, 'xyz'],   # replace the last word
        [0, 0, 'q,'],    # insert at the very beginning (shifts everything)
        [2, 0, 'zz'],    # insert in the middle
        [4, 2, ''],      # delete two characters
        [0, 1, '9'],     # turn a word into a number (other alternative)
        [0, 0, ''],      # no-op edit
      ])
    end

    it 'tracks a full reparse when the list grows and shrinks' do
      expect_edits_to_match_full_reparse(parser, 'a,bb,c', [
        [6, 0, ',dddd'], # append an item
        [0, 5, ''],      # delete the first two items
      ])
    end

    it 'reuses unchanged regions (cache hit evidence)' do
      session = described_class.new(parser)
      session.parse('aaa,bbb,ccc')
      session.replace(8, 3, 'xyz')

      expect(session.cache_hits).to be > 0
      expect(session.cache_misses).to be > 0

      # The unchanged prefix was not re-read; the re-parsed range covers
      # the edited word only.
      range = session.reparse_range
      expect(range.begin).to be > 0
      expect(range.begin).to be <= 8
      expect(range.end).to be >= 11
    end

    it 'exposes insert, delete and replace helpers' do
      session = described_class.new(parser)
      session.parse('aaa,bbb')

      expect(session.insert(4, 'x,')).to eq(parser.parse('aaa,x,bbb'))
      expect(session.delete(0, 4)).to eq(parser.parse('x,bbb'))
      expect(session.replace(2, 1, 'z')).to eq(parser.parse('x,zbb'))
    end

    it 'keeps working after a failed edit' do
      session = described_class.new(parser)
      session.parse('aaa,bbb')

      expect { session.insert(0, '!') }.to raise_error(Parslet::ParseFailed)
      expect(
        tree_signature(session.delete(0, 1))).to eq(
        tree_signature(parser.parse('aaa,bbb')))
    end
  end

  context 'with lookahead' do
    let(:parser) { SessionLookaheadParser.new }

    it 'invalidates cached results when the lookahead-read region changes' do
      session = described_class.new(parser)
      expect(session.parse('ab')).to eq(parser.parse('ab'))

      # Position 1 was only read by the lookahead, never consumed. A cache
      # keyed on consumed input alone would wrongly keep the result.
      expect { session.replace(1, 1, 'c') }.to raise_error(Parslet::ParseFailed)
      expect { parser.parse('ac') }.to raise_error(Parslet::ParseFailed)
    end
  end

  context 'with failed branches (counter-examples)' do
    it 'invalidates entries whose failed branch read the end of input' do
      parser = SessionPrematureParser.new
      session = described_class.new(parser)

      expect(session.parse('ab')).to eq('ab')

      # Appending a 'c' makes the previously failed str('abc') branch
      # match. A cache that only tracks consumed input would return the
      # stale 'ab' here.
      result = session.insert(2, 'c')
      expect(result.str).to eq('abc')
      expect(tree_signature(result)).to eq(
        tree_signature(parser.parse('abc')))
    end

    it 'invalidates entries whose failed branch read the edited character' do
      parser = SessionFailedBranchParser.new
      session = described_class.new(parser)

      expect(session.parse('bc')).to eq(parser.parse('bc'))

      # The edit turns the input into "bx", which the previously failed
      # str('bx') branch now matches.
      result = session.replace(1, 1, 'x')
      expect(result).to eq(parser.parse('bx'))
      expect(result[:w].str).to eq('bx')
      expect(tree_signature(result)).to eq(
        tree_signature(parser.parse('bx')))
    end
  end

  context 'with captures and dynamic rules' do
    let(:parser) { SessionTagParser.new }

    it 'replays captures from cache hits for re-evaluated dynamic rules' do
      session = described_class.new(parser)
      session.parse('#ab#ab!xyz')

      # The header (containing the capture) is unchanged and served from
      # the cache; the dynamic body must still see the captured tag. If
      # captures were not replayed on cache hits, this would raise
      # Parslet::Scope::NotFound instead of parsing.
      result = session.replace(7, 3, 'qq')
      expect(session.cache_hits).to be > 0
      expect(tree_signature(result)).to eq(
        tree_signature(parser.parse('#ab#ab!qq')))
    end

    it 'never reuses dynamic rules across edits' do
      session = described_class.new(parser)
      session.parse('#ab#ab!xyz')

      # Changing the tag name makes the dynamic body (which matches the
      # captured tag) fail. Reusing the dynamic rule's old result would
      # wrongly succeed.
      expect { session.replace(1, 2, 'xy') }.to raise_error(Parslet::ParseFailed)
      expect { parser.parse('#xy#ab!xyz') }.to raise_error(Parslet::ParseFailed)
    end
  end

  context 'with multiline input' do
    let(:parser) { SessionLinesParser.new }

    it 'updates slice offsets and line/column information after shifts' do
      session = described_class.new(parser)
      session.parse("foo\nbar\n")

      result = session.insert(0, "x\n")

      expect(tree_signature(result)).to eq(
        tree_signature(parser.parse("x\nfoo\nbar\n")))

      last = result.last[:line]
      expect(last.str).to eq('bar')
      expect(last.offset).to eq(6)
      expect(last.line_and_column).to eq([3, 1])
    end

    it 'tracks a full reparse when deleting lines' do
      expect_edits_to_match_full_reparse(parser, "aa\nbb\ncc\n", [
        [3, 3, ''],      # delete the middle line
        [0, 0, "x\ny\n"], # prepend two lines
        [6, 2, ''],      # delete within a line
      ])
    end
  end

  context 'with multibyte characters' do
    let(:parser) { SessionUtf8Parser.new }

    it 'tracks a full reparse across multibyte edits' do
     expect_edits_to_match_full_reparse(parser, 'hé,wo', [
       [0, 0, 'ß'],     # insert a multibyte character at the start
        [4, 2, 'xy'],    # replace after the multibyte character
        [2, 1, ''],      # delete the multibyte character
      ])
    end
  end
end
