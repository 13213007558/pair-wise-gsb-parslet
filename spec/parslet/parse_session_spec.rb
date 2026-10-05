require 'spec_helper'

describe Parslet::ParseSession do
  include Parslet

  def feed_in_byte_chunks(parser, input, chunk_sizes)
    session = parser.parse_session
    offset = 0

    chunk_sizes.each do |size|
      chunk = input.byteslice(offset, size)
      session.feed(chunk)
      offset += size
      expect(session).to be_waiting
    end

    session.finish
    session
  end

  def byte_chunk_sizes(length)
    Enumerator.new do |yielder|
      (1...2 ** length).each do |mask|
        sizes = []
        run = 1
        (length - 1).times do |index|
          if mask[index] == 1
            run += 1
          else
            sizes << run
            run = 1
          end
        end
        sizes << run
        yielder.yield(sizes)
      end
    end
  end

  it 'does not commit an ordered choice until EOF or contradiction' do
    parser = str('ab') | str('a')
    session = parser.parse_session

    session.feed('a')
    expect(session).to be_waiting
    expect(session.pause_pos).to eq(0)
    expect(session.retained_bytesize).to eq(1)

    session.finish
    expect(session).to be_success
    expect(session.result.to_s).to eq('a')

    session = parser.parse_session
    session.feed('a')
    session.feed('b')
    session.finish
    expect(session).to be_success
    expect(session.result.to_s).to eq('ab')
  end

  it 'reports a definite failure without waiting for EOF' do
    parser = str('ab') | str('a')
    session = parser.parse_session

    session.feed('x')
    expect(session).to be_failure
    expect(session.error).to be_a(Parslet::ParseFailed)
  end

  it 'waits for an unfinished UTF-8 character' do
    parser = any
    session = parser.parse_session
    bytes = 'é'.bytes

    session.feed(bytes.first.chr(Encoding::BINARY))
    expect(session).to be_waiting
    expect(session.retained_bytesize).to eq(1)

    session.feed(bytes.last.chr(Encoding::BINARY))
    session.finish
    expect(session).to be_success
    expect(session.result.to_s).to eq('é')
  end

  it 'continues repetitions across chunks without reparsing history' do
    parser = str('a').repeat.as(:as)
    session = parser.parse_session

    100.times do
      session.feed('a')
      expect(session).to be_waiting
    end

    session.finish
    expect(session.result[:as]).to eq('a' * 100)
  end

  it 'releases committed repetition input while keeping captures' do
    parser = match['ab'].capture(:first) >>
      dynamic { |_, context| str(context.captures[:first]) }
    session = parser.parse_session

    session.feed('a')
    expect(session).to be_waiting
    expect(session.retained_bytesize).to eq(1)

    session.feed('a')
    session.finish
    expect(session).to be_success
    expect(session.result.to_s).to eq('aa')
  end

  it 'keeps captures readable after their source bytes have been released' do
    parser = (str('a').capture(:first) >> str('|').ignore).as(:header) >>
      str(';') >>
      dynamic { |_, context| str(context.captures[:first]) }.as(:tail)
    session = parser.parse_session

    session.feed('a|;')
    expect(session).to be_waiting
    expect(session.pause_pos).to eq(0)
    expect(session.retained_bytesize).to eq(3)

    session.feed('a')
    session.finish
    expect(session).to be_success
    expect(session.retained_bytesize).to eq(0)
    first = session.result[:header]
    expect(first.to_s).to eq('a')
    expect(first.offset).to eq(0)
    expect(session.result[:tail].to_s).to eq('a')
  end

  it 'preserves lookahead across chunks' do
    parser = str('a').present? >> str('ab')
    session = parser.parse_session

    session.feed('a')
    expect(session).to be_waiting
    session.feed('b')
    session.finish
    expect(session.result.to_s).to eq('ab')
  end

  it 'matches normal parsing for every short byte chunking' do
    parsers = {
      'short prefix' => str('aéb') | str('a'),
      'sequence' => str('a') >> str('éb'),
      'utf8' => any >> str('éb'),
      'repetition' => str('a').repeat >> str('éb'),
    }

    input = 'aéb'
    expected = {
      'short prefix' => 'aéb',
      'sequence' => 'aéb',
      'utf8' => 'aéb',
      'repetition' => 'aéb',
    }

    byte_chunk_sizes(input.bytesize).each do |sizes|
      parsers.each do |name, parser|
        result = feed_in_byte_chunks(parser, input, sizes)
        expect(result).to be_success
        expect(result.result.to_s).to eq(expected.fetch(name))
        expect(result.result.to_s).to eq(parser.parse(input).to_s)
      end
    end
  end

  it 'matches a normal parse failure for every short byte chunking' do
    parser = str('abc')
    input = 'abd'

    byte_chunk_sizes(input.bytesize).each do |sizes|
      session = parser.parse_session
      offset = 0
      sizes.each do |size|
        session.feed(input.byteslice(offset, size))
        offset += size
      end
      session.finish
      expect(session).to be_failure
      expect(session.error).to be_a(Parslet::ParseFailed)
    end
  end
end
