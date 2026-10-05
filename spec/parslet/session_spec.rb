require 'spec_helper'

describe Parslet::Session do
  def session_for(atom, options={})
    Parslet::Session.new(atom, options)
  end

  # Feeds +input+ to a fresh session for +atom+ in chunks of +size+
  # characters (byte chunks when :bytes is given), then finishes the
  # session. Returns the session.
  def run_session(atom, input, size=1, options={})
    session = Parslet::Session.new(atom, options)
    if options.delete(:bytes)
      input.bytes.each_slice(size) do |slice|
        session.feed(slice.pack('C*'))
        break unless session.waiting?
      end
    else
      input.chars.each_slice(size) do |slice|
        session.feed(slice.join)
        break unless session.waiting?
      end
    end
    session.finish if session.waiting?
    session
  end

  describe 'ordered choice' do
    let(:atom) { Parslet.str('ab') | Parslet.str('a') }

    it 'waits on a lone prefix instead of committing to the short branch' do
      session = session_for(atom)
      expect(session.feed('a')).to eq(:waiting)
      expect(session).to be_waiting
    end

    it 'prefers the long branch once it completes' do
      session = session_for(atom)
      session.feed('a')
      session.feed('b')
      expect(session.finish).to eq(:success)
      expect(session.result).to eq('ab')
    end

    it 'falls back to the short branch at end of input' do
      session = session_for(atom)
      session.feed('a')
      expect(session.finish).to eq(:success)
      expect(session.result).to eq('a')
    end

    it 'fails definitively on input that can never match' do
      session = session_for(atom)
      expect(session.feed('x')).to eq(:failure)
      expect(session.error).to be_a(Parslet::ParseFailed)
    end

    it 'fails when the short branch matched but input continues' do
      session = session_for(atom)
      session.feed('a')
      expect(session.feed('c')).to eq(:failure)
    end
  end

  describe 'state machine' do
    let(:atom) { Parslet.str('ok') }

    it 'starts out waiting' do
      expect(session_for(atom)).to be_waiting
    end

    it 'does not succeed before finish, even on a complete match' do
      session = session_for(atom)
      expect(session.feed('ok')).to eq(:waiting)
      expect(session.finish).to eq(:success)
      expect(session).to be_success
    end

    it 'rejects extra input arriving after a complete match' do
      session = session_for(atom)
      session.feed('ok')
      expect(session.feed('!')).to eq(:failure)
      expect(session.error.message).to eq(
        %(Don't know what to do with "!" at line 1 char 3.))
    end

    it 'raises when fed after success' do
      session = session_for(atom)
      session.feed('ok')
      session.finish
      expect { session.feed('x') }.
        to raise_error(Parslet::Session::FinishedError)
    end

    it 'raises when fed after failure' do
      session = session_for(atom)
      session.feed('xx')
      expect { session.feed('x') }.
        to raise_error(Parslet::Session::FinishedError)
    end

    it 'raises when finished twice' do
      session = session_for(atom)
      session.feed('ok')
      session.finish
      expect { session.finish }.
        to raise_error(Parslet::Session::FinishedError)
    end

    it 'tolerates empty chunks' do
      session = session_for(atom)
      expect(session.feed('')).to eq(:waiting)
      session.feed('ok')
      expect(session.finish).to eq(:success)
    end

    it 'exposes result and error only in the matching state' do
      session = session_for(atom)
      expect(session.result).to be_nil
      expect(session.error).to be_nil
      session.feed('ok')
      session.finish
      expect(session.result).to eq('ok')
      expect(session.error).to be_nil
    end
  end

  describe 'repetition' do
    it 'waits for more input instead of concluding early' do
      session = session_for(Parslet.str('a').repeat)
      expect(session.feed('aaa')).to eq(:waiting)
      expect(session.feed('aa')).to eq(:waiting)
      expect(session.finish).to eq(:success)
      expect(session.result).to eq('aaaaa')
    end

    it 'fails at finish when the minimum is not reached' do
      session = session_for(Parslet.str('a').repeat(2, 3))
      session.feed('a')
      expect(session.finish).to eq(:failure)
    end

    it 'stops at the maximum and continues the sequence' do
      atom = Parslet.str('a').repeat(1, 2) >> Parslet.str('b')
      expect(run_session(atom, 'aab', 1).result).to eq('aab')
    end

    it 'handles maybe across chunks' do
      atom = Parslet.str('a') >> Parslet.str('b').maybe
      expect(run_session(atom, 'ab', 1).result).to eq('ab')
      expect(run_session(atom, 'a', 1).result).to eq('a')
    end
  end

  describe 'lookahead' do
    it 'suspends positive lookahead until it can decide' do
      atom = Parslet.str('ab').present? >> Parslet.str('ab')
      session = session_for(atom)
      expect(session.feed('a')).to eq(:waiting)
      expect(session.feed('b')).to eq(:waiting)
      expect(session.finish).to eq(:success)
      expect(session.result).to eq('ab')
    end

    it 'suspends negative lookahead until it can decide' do
      atom = Parslet.str('ab').absent? >> Parslet.any
      session = session_for(atom)
      expect(session.feed('a')).to eq(:waiting)
      expect(session.feed('x')).to eq(:failure)  # 'ax' then leftover... 
    end

    it 'lets negative lookahead succeed on real mismatch' do
      atom = Parslet.str('ab').absent? >> Parslet.any >> Parslet.any
      expect(run_session(atom, 'ax', 1).result).to eq('ax')
    end

    it 'fails negative lookahead when the pattern completes' do
      atom = Parslet.str('ab').absent? >> Parslet.any
      session = session_for(atom)
      session.feed('a')
      expect(session.feed('b')).to eq(:failure)
    end
  end

  describe 'multi-byte characters' do
    it 'waits for a character split over chunks instead of failing' do
      session = session_for(Parslet.str('héllo'))
      'héllo'.bytes.each do |byte|
        expect(session.feed(byte.chr(Encoding::BINARY))).to eq(:waiting)
      end
      expect(session.finish).to eq(:success)
      expect(session.result).to eq('héllo')
    end

    it 'waits on a truncated character for any' do
      session = session_for(Parslet.any)
      expect(session.feed('é'.bytes.first.chr(Encoding::BINARY))).to eq(:waiting)
      expect(session.feed('é'.bytes.last.chr(Encoding::BINARY))).to eq(:waiting)
      expect(session.finish).to eq(:success)
      expect(session.result).to eq('é')
    end

    it 'reports correct character offsets for multi-byte input' do
      atom = Parslet.str('é').as(:e) >> Parslet.str('x').as(:x)
      session = run_session(atom, 'éx', 1, bytes: true)
      expect(session.result[:e].offset).to eq(0)
      expect(session.result[:x].offset).to eq(1)
    end
  end

  describe 'equivalence with #parse' do
    let(:parser_class) do
      Class.new(Parslet::Parser) do
        rule(:space) { match('\s').repeat(1) }
        rule(:space?) { space.maybe }
        rule(:integer) { (str('-').maybe >> match('[0-9]').repeat(1)).as(:int) >> space? }
        rule(:op) { match('[+-]').as(:op) >> space? }
        rule(:sum) { (integer >> (op >> integer).repeat).as(:sum) }
        root(:sum)
      end
    end
    let(:parser) { parser_class.new }

    inputs = [
      '1',
      '1 + 22 + 333 - 4',
      '-5 - -6',
    ]

    inputs.each do |input|
      context "for input #{input.inspect}" do
        let(:expected) { parser.parse(input) }

        it 'matches batch parse for every chunk size' do
          (1..input.size).each do |size|
            session = run_session(parser, input, size)
            expect(session.state).to eq(:success), "chunk size #{size}"
            expect(session.result).to eq(expected)
          end
        end

        it 'matches batch parse when fed byte by byte' do
          session = run_session(parser, input, 1, bytes: true)
          expect(session.state).to eq(:success)
          expect(session.result).to eq(expected)
        end
      end
    end

    it 'matches batch parse for multi-byte input in all chunkings' do
      klass = Class.new(Parslet::Parser) do
        rule(:word) { match('[^ ]').repeat(1).as(:w) }
        rule(:line) { (word >> str(' ').maybe).repeat }
        root(:line)
      end
      parser = klass.new
      input = 'héllo wörld éé'
      expected = parser.parse(input)

      (1..input.size).each do |size|
        session = run_session(parser, input, size)
        expect(session.state).to eq(:success), "chunk size #{size}"
        expect(session.result).to eq(expected)
      end

      session = run_session(parser, input, 1, bytes: true)
      expect(session.result).to eq(expected)
    end

    it 'produces the same failure as batch parse' do
      input = '1 + x'
      batch_error = begin
        parser.parse(input)
      rescue Parslet::ParseFailed => exception
        exception
      end

      session = run_session(parser, input, 1)
      expect(session.state).to eq(:failure)
      expect(session.error).to be_a(Parslet::ParseFailed)
      expect(session.error.message).to eq(batch_error.message)
      expect(session.error.parse_failure_cause).not_to be_nil
    end

    it 'fails like batch parse on premature end of input' do
      input = '1 +'
      batch_error = begin
        parser.parse(input)
      rescue Parslet::ParseFailed => exception
        exception
      end

      session = run_session(parser, input, 1)
      expect(session.state).to eq(:failure)
      expect(session.error.message).to eq(batch_error.message)
    end
  end

  describe 'grammars using parser features' do
    it 'parses infix expressions chunk by chunk' do
      klass = Class.new(Parslet::Parser) do
        rule(:space?) { match('\s').repeat.maybe }
        rule(:integer) { match('[0-9]').repeat(1).as(:int) >> space? }
        rule(:op_plus) { str('+').as(:plus) >> space? }
        rule(:op_mult) { str('*').as(:mult) >> space? }
        rule(:expression) do
          infix_expression(integer, [op_mult, 2, :left], [op_plus, 1, :left])
        end
        root(:expression)
      end
      input = '1+2*3+4'
      session = run_session(klass.new, input, 1)
      expect(session.result).to eq(klass.new.parse(input))
    end

    it 'supports capture and dynamic' do
      atom = Parslet.match['ab'].capture(:first) >>
        Parslet.dynamic { |_, ctx| Parslet.str(ctx.captures[:first]) }
      expect(run_session(atom, 'aa', 1).result).to eq('aa')
      expect(run_session(atom, 'bb', 1).result).to eq('bb')
      expect(run_session(atom, 'ab', 1).state).to eq(:failure)
    end

    it 'supports scopes' do
      atom = Parslet.scope { Parslet.str('a').capture(:x) } >> Parslet.str('b')
      expect(run_session(atom, 'ab', 1).result).to eq('ab')
    end

    it 'supports named subtrees' do
      atom = (Parslet.str('a').as(:letter) >> Parslet.str('b').as(:other)).as(:pair)
      session = run_session(atom, 'ab', 1)
      expect(session.result).to eq(pair: { letter: 'a', other: 'b' })
    end
  end

  describe 'input release' do
    it 'releases input the parser cannot backtrack to' do
      session = session_for(Parslet.str('a').repeat)
      session.feed('aaaa')
      expect(session.retained_bytes).to eq(0)
      session.feed('aa')
      expect(session.retained_bytes).to eq(0)
      expect(session.finish).to eq(:success)
      expect(session.result).to eq('aaaaaa')
    end

    it 'retains input that an open alternative can still backtrack to' do
      session = session_for(Parslet.str('ab') | Parslet.str('a'))
      session.feed('a')
      expect(session.retained_bytes).to eq(1)
    end

    it 'retains input inside a lookahead' do
      atom = Parslet.str('ab').present? >> Parslet.str('ab')
      session = session_for(atom)
      session.feed('a')
      expect(session.retained_bytes).to eq(1)
    end

    it 'keeps everything when release is disabled' do
      session = session_for(Parslet.str('a').repeat, release: false)
      session.feed('aaaa')
      expect(session.retained_bytes).to eq(4)
    end

    it 'keeps slices and their offsets readable after release' do
      klass = Class.new(Parslet::Parser) do
        rule(:word) { match('[a-z]').repeat(1).as(:word) >> str(' ').maybe }
        rule(:sentence) { word.repeat }
        root(:sentence)
      end
      session = session_for(klass.new)
      'hello world'.each_char { |char| session.feed(char) }
      expect(session.retained_bytes).to be < 11
      session.finish

      words = session.result.map { |entry| entry[:word] }
      expect(words.map(&:to_s)).to eq(%w(hello world))
      expect(words.map(&:offset)).to eq([0, 6])
      expect(words.last.line_and_column).to eq([1, 7])
    end

    it 'exposes the pause position' do
      session = session_for(Parslet.str('ab') | Parslet.str('a'))
      session.feed('a')
      expect(session.position).to eq(0)

      other = session_for(Parslet.str('a').repeat)
      other.feed('aaa')
      expect(other.position).to eq(3)
    end

    it 'reports errors after failures cascade through released input' do
      atom = Parslet.str('x') >> Parslet.str('a').repeat
      session = session_for(atom)
      session.feed('xaa')
      expect(session.retained_bytes).to eq(0)
      expect(session.feed('b')).to eq(:failure)

      batch_error = begin
        atom.parse('xaab')
      rescue Parslet::ParseFailed => exception
        exception
      end
      expect(session.error.message).to eq(batch_error.message)
    end

    it 'keeps line and column information for released input' do
      atom = Parslet.str('a').repeat(1) >> Parslet.str("\n") >> Parslet.str('y')
      session = session_for(atom)
      "aaaa\nx".each_char do |char|
        session.feed(char)
        break unless session.waiting?
      end
      expect(session.state).to eq(:failure)
      expect(session.error.message).to include('at line 2 char 1')
    end

    it 'bounds retained memory on long streams' do
      session = session_for(Parslet.str('a').repeat)
      100.times { session.feed('a' * 1000) }
      expect(session.retained_bytes).
        to be < 2 * Parslet::StreamingSource::RELEASE_THRESHOLD
      expect(session.position).to eq(100_000)
      expect(session.finish).to eq(:success)
      expect(session.result.to_s.size).to eq(100_000)
      expect(session.result.offset).to eq(0)
    end
  end

  describe 'Parslet::Atoms::Base#session' do
    it 'creates a session for any atom' do
      session = Parslet.str('x').session
      expect(session).to be_a(Parslet::Session)
      session.feed('x')
      expect(session.finish).to eq(:success)
    end

    it 'creates a session for a parser' do
      klass = Class.new(Parslet::Parser) do
        rule(:a) { str('a') }
        root(:a)
      end
      session = klass.new.session
      session.feed('a')
      expect(session.finish).to eq(:success)
    end
  end
end
