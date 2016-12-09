require 'spec_helper'
require_relative '../lib/stream_reader'
require 'logger'

describe StreamReader do
  it 'has a logger' do
    expect(described_class.logger).to be_a(Logger)
  end

  describe 'spawning runner threads' do
    let(:client) { Aws::Kinesis::Client.new }
    let(:reader) { StreamReader.new(stream_name: 'test_stream', client: client) }

    it 'spawns a ShardReader for each shard returned' do
      allow_any_instance_of(ShardReader).to receive(:run).and_return(Thread.new { })
      expect(ShardReader).to receive(:new).twice.and_call_original
      reader.run! do
        # No-op
      end
    end

    it 'starts and stops gracefully' do
      stub_processor = double
      expect(stub_processor).to receive(:process).at_least(:once)
      reader.run! { |record| stub_processor.process }
      sleep 3
      reader.stop!
    end
  end
end
