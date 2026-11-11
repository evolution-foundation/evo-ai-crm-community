require 'rails_helper'

RSpec.describe EvoFlow::BackfillContactLabelsWorker, type: :worker do
  let(:fake_alfred) { {} }

  before do
    allow(Redis::Alfred).to receive(:get) { |k| fake_alfred[k] }
    allow(Redis::Alfred).to receive(:set) { |k, v, **_| fake_alfred[k] = v.to_s }
    allow(Redis::Alfred).to receive(:incr) { |k| fake_alfred[k] = (fake_alfred[k].to_i + 1).to_s }
    allow(Redis::Alfred).to receive(:delete) { |k| fake_alfred.delete(k) }

    allow(EvoFlow).to receive(:enabled?).and_return(true)
    allow(EvoFlow::PublishEventWorker).to receive(:perform_async)
    allow(Label).to receive(:pluck).with(:title, :id).and_return([])
  end

  def uuid(suffix)
    format('%<a>08x-%<b>04x-%<c>04x-%<d>04x-%<e>012x', a: suffix, b: 0, c: 0, d: 0, e: suffix)
  end

  def build_tag(name:)
    instance_double(ActsAsTaggableOn::Tag, name: name)
  end

  def build_tagging(id:, taggable_id: uuid(1), tag: build_tag(name: 'suporte'),
                     created_at: Time.zone.parse('2026-01-01T00:00:00Z'))
    instance_double(
      ActsAsTaggableOn::Tagging,
      id: id, taggable_id: taggable_id, tag: tag, created_at: created_at
    )
  end

  def stub_taggings_relation(records)
    relation = instance_double(ActiveRecord::Relation)
    %i[joins where order].each { |chain| allow(relation).to receive(chain).and_return(relation) }
    allow(relation).to receive(:find_each) do |**opts, &block|
      start_at = opts[:start]
      filtered = start_at ? records.select { |r| r.id > start_at } : records
      filtered.each { |r| block.call(r) }
    end
    allow(ActsAsTaggableOn::Tagging).to receive(:joins).and_return(relation)
    relation
  end

  describe 'sidekiq configuration' do
    it 'uses the integrations queue with retry: 2' do
      expect(described_class.sidekiq_options['queue']).to eq(:integrations)
      expect(described_class.sidekiq_options['retry']).to eq(2)
    end
  end

  describe 'integration feature gate' do
    it 'short-circuits when EvoFlow.enabled? is false' do
      allow(EvoFlow).to receive(:enabled?).and_return(false)
      allow(Rails.logger).to receive(:warn)

      described_class.new.perform(nil, 'dry_run' => true)

      expect(Rails.logger).to have_received(:warn).with(/integration is disabled/)
      expect(EvoFlow::PublishEventWorker).not_to have_received(:perform_async)
    end
  end

  describe 'dry_run (default)' do
    it 'does not enqueue PublishEventWorker and does not write the live cursor' do
      stub_taggings_relation([build_tagging(id: uuid(10))])

      described_class.new.perform(nil, 'dry_run' => true)

      expect(EvoFlow::PublishEventWorker).not_to have_received(:perform_async)
      expect(fake_alfred.keys.grep(/^backfill:cursor:labels:/)).to be_empty
    end

    it 'logs a would_backfill summary and one sample_payload line' do
      stub_taggings_relation([build_tagging(id: uuid(10)), build_tagging(id: uuid(11))])
      logged = []
      allow(Rails.logger).to receive(:info) { |m| logged << m }

      described_class.new.perform(nil, 'dry_run' => true)

      expect(logged.grep(/would_backfill account=ALL count=2/)).not_to be_empty
      expect(logged.grep(/sample_payload/).size).to eq(1)
    end
  end

  describe 'publish path' do
    it 'enqueues one PublishEventWorker job per tagging via /events/identify' do
      stub_taggings_relation([build_tagging(id: uuid(10), taggable_id: uuid(1), tag: build_tag(name: 'suporte'))])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(EvoFlow::PublishEventWorker).to have_received(:perform_async) do |path, payload|
        expect(path).to eq('/events/identify')
        expect(payload['eventName']).to eq('contact.label.added')
        expect(payload['contactId']).to eq(uuid(1))
        expect(payload['traits']['labelName']).to eq('suporte')
        expect(payload['traits']['source']).to eq('backfill')
        expect(payload['messageId']).to match(/\A[0-9a-f]{64}\z/)
      end
    end

    it 'resolves labelId from the CRM Label table when the title matches' do
      allow(Label).to receive(:pluck).with(:title, :id).and_return([['suporte', uuid(99)]])
      stub_taggings_relation([build_tagging(id: uuid(10), tag: build_tag(name: 'suporte'))])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(EvoFlow::PublishEventWorker).to have_received(:perform_async) do |_path, payload|
        expect(payload['traits']['labelId']).to eq(uuid(99))
      end
    end

    it 'falls back to the label name as labelId when no matching Label exists' do
      stub_taggings_relation([build_tagging(id: uuid(10), tag: build_tag(name: 'sem-cadastro'))])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(EvoFlow::PublishEventWorker).to have_received(:perform_async) do |_path, payload|
        expect(payload['traits']['labelId']).to eq('sem-cadastro')
      end
    end

    it 'uses the tagging created_at as the event timestamp' do
      created_at = Time.zone.parse('2025-06-15T12:00:00Z')
      stub_taggings_relation([build_tagging(id: uuid(10), created_at: created_at)])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(EvoFlow::PublishEventWorker).to have_received(:perform_async) do |_path, payload|
        expect(payload['timestamp']).to eq(created_at.utc.iso8601)
      end
    end

    it 'increments the processed counter per payload' do
      stub_taggings_relation(Array.new(3) { |i| build_tagging(id: uuid(i + 10)) })

      described_class.new.perform(nil, 'dry_run' => false)

      expect(fake_alfred['evo_flow_backfill_labels:processed']).to eq('3')
    end
  end

  describe 'skip conditions' do
    it 'skips and increments :skipped when taggable_id is nil' do
      dangling = build_tagging(id: uuid(10), taggable_id: nil)
      stub_taggings_relation([dangling])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(EvoFlow::PublishEventWorker).not_to have_received(:perform_async)
      expect(fake_alfred['evo_flow_backfill_labels:skipped']).to eq('1')
    end

    it 'skips and increments :skipped when the tag name is blank' do
      dangling = build_tagging(id: uuid(10), tag: build_tag(name: ''))
      stub_taggings_relation([dangling])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(EvoFlow::PublishEventWorker).not_to have_received(:perform_async)
      expect(fake_alfred['evo_flow_backfill_labels:skipped']).to eq('1')
    end
  end

  describe 'cursor resumability with UUID primary keys' do
    it 'passes a string cursor to find_each(start:) and clears it on completion' do
      records = [build_tagging(id: uuid(10)), build_tagging(id: uuid(11))]
      relation = stub_taggings_relation(records)
      cursor_value = uuid(5)
      fake_alfred['backfill:cursor:labels:ALL'] = cursor_value

      described_class.new.perform(nil, 'dry_run' => false)

      expect(relation).to have_received(:find_each)
        .with(hash_including(start: cursor_value, batch_size: 1000))
      expect(fake_alfred['backfill:cursor:labels:ALL']).to be_nil
    end

    it 'omits the start: arg when no cursor is set' do
      relation = stub_taggings_relation([build_tagging(id: uuid(10))])

      described_class.new.perform(nil, 'dry_run' => false)

      expect(relation).to have_received(:find_each) do |**opts|
        expect(opts).not_to include(:start)
        expect(opts[:batch_size]).to eq(1000)
      end
    end
  end

  describe 'retries exhausted -> Wisper :evo_flow_backfill_failed' do
    let(:listener) do
      Class.new do
        attr_reader :received

        def evo_flow_backfill_failed(args)
          @received = args
        end
      end.new
    end

    it 'broadcasts with account_id + sanitized error' do
      job = { 'args' => [nil, {}], 'class' => described_class.name }
      # A generic StandardError, not EvoFlow::HTTPError: this worker never
      # calls EvoFlow::Client directly (each row is a fire-and-forget enqueue
      # to PublishEventWorker), so its retriable failures are ordinary
      # exceptions, not HTTP-layer ones.
      exception = StandardError.new('boom')

      Wisper.subscribe(listener) do
        described_class.sidekiq_retries_exhausted_block.call(job, exception)
      end

      expect(listener.received).to be_present
      expect(listener.received[:data]).to include(:account_id, :error)
      expect(listener.received[:data][:error]).to include('boom')
    end
  end
end
