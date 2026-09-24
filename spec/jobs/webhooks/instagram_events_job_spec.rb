# frozen_string_literal: true

require 'rails_helper'

# The routing predicate is the only thing separating a real notification from
# Meta's test event: both arrive in the same `changes` envelope.
RSpec.describe Webhooks::InstagramEventsJob, type: :job do
  subject(:job) { described_class.new }

  let(:comment_entry) do
    { 'id' => '17841400000000000', 'time' => 1_756_242_000,
      'changes' => [{ 'field' => 'comments',
                      'value' => { 'from' => { 'id' => '17841400000000001', 'username' => 'cliente' },
                                   'id' => '18000000000000000', 'media' => { 'id' => '18100000000000000' },
                                   'text' => 'Que top hein 🔥🔥' } }] }
  end
  let(:test_entry) do
    { 'id' => '0', 'time' => 1_527_459_824,
      'changes' => [{ 'field' => 'messages',
                      'value' => { 'sender' => { 'id' => '12334' }, 'recipient' => { 'id' => '23245' },
                                   'timestamp' => '1527459824',
                                   'message' => { 'mid' => 'random_mid', 'text' => 'random_text' } } }] }
  end
  let(:dm_entry) do
    { 'id' => '17841400000000000', 'time' => 1_756_242_000,
      'messaging' => [{ 'sender' => { 'id' => '17841400000000001' }, 'recipient' => { 'id' => '17841400000000000' },
                        'timestamp' => 1_756_242_000, 'message' => { 'mid' => 'mid.1', 'text' => 'oi' } }] }
  end

  # process_entries is the body `perform` runs under the Redis mutex; driving it
  # directly keeps the routing proof off Redis.
  def process(entry)
    job.send(:process_entries, [entry])
  end

  it 'skips a comment notification without raising and without treating it as a test event' do
    expect(Instagram::TestEventService).not_to receive(:new)
    allow(Rails.logger).to receive(:info)

    expect { process(comment_entry) }.not_to raise_error

    expect(Rails.logger).to have_received(:info).with(/Skipping unsupported change fields \["comments"\]/)
  end

  it "still routes Meta's test event (changes + fixed pair) to the test service" do
    service = instance_double(Instagram::TestEventService, perform: true)
    expect(Instagram::TestEventService).to receive(:new)
      .with(hash_including('sender' => { 'id' => '12334' })).and_return(service)

    process(test_entry)

    expect(service).to have_received(:perform)
  end

  it 'routes a real DM (messaging envelope) to the message path, never to the test service' do
    expect(Instagram::TestEventService).not_to receive(:new)
    allow(Channel::Instagram).to receive(:find_by).and_return(nil)
    allow(Channel::FacebookPage).to receive(:find_by).and_return(nil)

    expect { process(dm_entry) }.not_to raise_error
    expect(Channel::Instagram).to have_received(:find_by).with(instagram_id: '17841400000000000')
  end

  it 'does not confuse a changes value that merely has a sender with the test event' do
    entry = comment_entry.deep_dup
    entry['changes'][0]['value']['sender'] = { 'id' => '12334' }
    expect(Instagram::TestEventService).not_to receive(:new)

    expect { process(entry) }.not_to raise_error
  end

  it 'skips a changes value whose sender is not a hash instead of dying on it' do
    entry = comment_entry.deep_dup
    entry['changes'][0]['value']['sender'] = '12334'
    allow(Rails.logger).to receive(:info)

    expect { process(entry) }.not_to raise_error

    expect(Rails.logger).to have_received(:info).with(/Skipping unsupported change fields/)
  end

  # `changes` comes off the wire, so a shape the job did not expect must not kill the entry.
  describe 'a malformed changes envelope' do
    it 'skips changes sent as an object instead of an array' do
      entry = comment_entry.merge('changes' => { 'field' => 'comments', 'value' => { 'text' => 'oi' } })
      expect(Instagram::TestEventService).not_to receive(:new)

      expect { process(entry) }.not_to raise_error
    end

    it 'skips changes sent as an array of strings' do
      entry = comment_entry.merge('changes' => %w[comments mentions])
      expect(Instagram::TestEventService).not_to receive(:new)

      expect { process(entry) }.not_to raise_error
    end

    it 'skips a change that carries no value, or a value that is not an object' do
      [{ 'field' => 'comments' }, { 'field' => 'comments', 'value' => 'text' }, { 'field' => 'comments', 'value' => nil }].each do |change|
        expect(Instagram::TestEventService).not_to receive(:new)

        expect { process(comment_entry.merge('changes' => [change])) }.not_to raise_error
      end
    end
  end
end
