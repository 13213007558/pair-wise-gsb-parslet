require 'spec_helper'

describe Parslet::Session do
  class SessionParser < Parslet::Parser
    root(:line)
    rule(:line) { number >> newline >> tag }
    rule(:number) { match['0-9'].repeat(1) }
    rule(:newline) { str("\n") }
    rule(:tag) { match['a-z'].repeat(1) }
  end

  class FailureBranchParser < Parslet::Parser
    root(:choice)
    rule(:choice) { rejected_branch | accepted_branch }
    rule(:rejected_branch) { str('x') >> str('z') }
    rule(:accepted_branch) { str('xyzkeep') }
  end

  class LookaheadParser < Parslet::Parser
    root(:word)
    rule(:word) { str('no').absent? >> match['a-z'].repeat(1) }
  end

  class PositiveLookaheadParser < Parslet::Parser
    root(:word)
    rule(:word) { str('ab').present? >> match['a-z'].repeat(1) }
  end

  class DynamicParser < Parslet::Parser
    root(:pairs)
    rule(:pairs) { pair.repeat(1) }
    rule(:pair) do
      match['ab'].capture(:letter).as(:letter) >>
        dynamic { |source, context| str(context.captures[:letter]) }
    end
  end

  class LocationParser < Parslet::Parser
    root(:line)
    rule(:line) { prefix >> newline >> tag.as(:tag) }
    rule(:prefix) { match['0-9é'].repeat(1) }
    rule(:newline) { str("\n") }
    rule(:tag) { match['a-z'].repeat(1) }
  end

  def full_parse(parser, text)
    source = Parslet::Source.new(text)
    success, value = parser.apply(source, Parslet::Atoms::Context.new, true)
    raise 'expected successful full parse' unless success

    parser.flatten(value)
  end

  def slices(value)
    return enum_for(:slices, value) unless block_given?

    case value
    when Parslet::Slice then yield value
    when Array then value.each { |item| slices(item) { |slice| yield slice } }
    when Hash then value.each_value { |item| slices(item) { |slice| yield slice } }
    end
  end

  def locations(value)
    slices(value).map do |slice|
      [slice.to_s, slice.offset, slice.line_and_column]
    end
  end

  def compare(result, parser, text)
    expected = full_parse(parser, text)
    expect(result.result).to eq(expected)
    expect(result.text).to eq(text)
    expect(locations(result.result)).to eq(locations(expected))
  end

  let(:parser) { SessionParser.new }

  it 'reuses unchanged prefix entries and reports the reparsed range' do
    session = parser.session("12\nab")
    result = session.insert(5, 'c')

    compare(result, parser, "12\nabc")
    expect(result.range).to eq([4, 6])
    expect(result.cache_hits).to be > 0
    expect(result.hit_offsets).to include(0, 3)
  end

  it 'supports deletion and rolls failed replacement state back' do
    session = parser.session("12\nabc")
    result = session.delete(4, 5)

    compare(result, parser, "12\nac")

    expect { session.replace(3, 4, "Z") }.to raise_error(Parslet::ParseFailed)
    expect(session.text).to eq("12\nac")
  end

  it 'accepts submitted edit operations described by old character coordinates' do
    session = parser.session("12\nab")
    result = session.submit(
      type: :insert,
      start: 5,
      text: 'c'
    )

    expect(result.reparsed_range).to eq(result.range)
    compare(result, parser, "12\nabc")
  end

  it 'updates offsets, lines and columns after multibyte insertion' do
    parser = LocationParser.new
    session = parser.session("1\nx")
    result = session.insert(1, "é")

    compare(result, parser, "1é\nx")
    tag = result.result[:tag]
    expect(tag.offset).to eq(3)
    expect(tag.line_and_column).to eq([2, 1])
  end

  it 'invalidates an edit inside a previously failed alternative branch' do
    parser = FailureBranchParser.new
    session = parser.session('xyzkeep')

    result = session.replace(2, 3, 'z')
    compare(result, parser, 'xyzkeep')

    expect { session.replace(1, 2, 'z') }.to raise_error(Parslet::ParseFailed)
    expect(session.text).to eq('xyzkeep')
  end

  it 'invalidates successful negative lookahead when rejected text is inserted' do
    parser = LookaheadParser.new
    session = parser.session('abc')

    expect { session.insert(0, 'no') }.to raise_error(Parslet::ParseFailed)
    expect(session.text).to eq('abc')
  end

  it 'invalidates successful positive lookahead when its inspected prefix changes' do
    parser = PositiveLookaheadParser.new
    session = parser.session('abc')

    expect { session.replace(0, 1, 'x') }.to raise_error(Parslet::ParseFailed)
    expect(session.text).to eq('abc')
  end

  it 'reruns dynamic rules and shifts captured slice coordinates' do
    parser = DynamicParser.new
    session = parser.session('aa')

    result = session.insert(0, 'bb')
    compare(result, parser, 'bbaa')
    expect(result.result.map { |pair| pair[:letter].offset }).to eq([0, 2])

    result = session.insert(4, 'aa')
    compare(result, parser, 'bbaaaa')
    expect(result.hit_offsets).to include(0)
  end

  it 'matches a sequence of valid edits against full reparses' do
    session = parser.session("12\nab")
    text = "12\nab"

    result = session.insert(5, 'z')
    text += 'z'
    compare(result, parser, text)

    result = session.replace(0, 1, '9')
    text = '9' + text[1..]
    compare(result, parser, text)
    expect(result.hit_offsets).not_to be_empty
  end
end
