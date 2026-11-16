require 'rails_helper'

RSpec.describe Internal::RemoveStaleRedisKeysJob do
  include ActiveJob::TestHelper

  let(:key) { OnlineStatusTracker.presence_key('Contact') }

  after { Redis::Alfred.delete(key) }

  it 'enqueues the cleanup job with the arguments it accepts' do
    expect { described_class.perform_now }.to have_enqueued_job(Internal::ProcessStaleRedisKeysJob).with(no_args)
  end

  it 'removes stale contact presence and keeps the fresh one' do
    Redis::Alfred.zadd(key, (OnlineStatusTracker::PRESENCE_DURATION + 1.minute).ago.to_i, 'stale-contact')
    Redis::Alfred.zadd(key, Time.zone.now.to_i, 'fresh-contact')

    perform_enqueued_jobs { described_class.perform_now }

    expect(Redis::Alfred.zscore(key, 'stale-contact')).to be_nil
    expect(Redis::Alfred.zscore(key, 'fresh-contact')).to be_present
  end
end
