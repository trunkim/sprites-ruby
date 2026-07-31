# frozen_string_literal: true

require "spec_helper"

RSpec.describe Sprites::NDJSONStream do
  it "maps incrementally, skips blank and malformed records, and closes after enumeration" do
    body = StringIO.new("\nnot-json\n{\"value\":1}\n{\"value\":2}\n")
    stream = described_class.new(body) { |data| data.fetch("value") }

    expect(stream.next_item).to eq(1)
    expect(stream.to_a).to eq([2])
    expect(stream).to be_closed
    expect(body).to be_closed
  end

  it "does not close when an Enumerator is requested but not consumed" do
    stream = described_class.new("{\"value\":1}\n") { |data| data.fetch("value") }

    enumerator = stream.each

    expect(enumerator).to be_a(Enumerator)
    expect(stream).not_to be_closed
    expect(enumerator.to_a).to eq([1])
    expect(stream).to be_closed
  end
end

RSpec.describe Sprites::CheckpointStream do
  it "requires a complete terminal event and closes on success" do
    stream = described_class.new("{\"type\":\"info\"}\n{\"type\":\"complete\"}\n")

    expect(stream.drain!).to be_nil
    expect(stream).to be_closed
  end

  it "fails closed on explicit error or missing complete" do
    error_stream = described_class.new("{\"type\":\"error\",\"error\":\"failed\"}\n")
    incomplete_stream = described_class.new("{\"type\":\"info\"}\n")

    expect { error_stream.drain! }.to raise_error(Sprites::Error, "failed")
    expect { incomplete_stream.drain! }.to raise_error(Sprites::Error, /without complete/)
    expect(error_stream).to be_closed
    expect(incomplete_stream).to be_closed
  end
end
