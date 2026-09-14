# frozen_string_literal: true

require 'rails_helper'

# No transactional fixtures: under them Rails sets `pool.lock_thread = true`, every
# thread gets the SAME connection and serializes on its own, which would defeat the
# point. Same shape as spec/lib/concurrent_index_migration_spec.rb.
RSpec.describe Conversation do
  self.use_transactional_tests = false

  # Asking for more connections than the pool holds hangs in ConnectionTimeoutError:
  # leave one for the main thread.
  let(:concurrency) { [ActiveRecord::Base.connection_pool.size - 1, 4].min }

  let!(:channel) { Channel::WebWidget.create!(website_url: "https://crm607-#{SecureRandom.hex(4)}.example.com") }
  let!(:inbox) { Inbox.create!(name: "CRM607 #{SecureRandom.hex(3)}", channel: channel) }
  let!(:contact) { Contact.create!(name: 'CRM607', email: "crm607-#{SecureRandom.hex(6)}@example.com") }
  let!(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(6)) }

  # Without transactional fixtures these rows COMMIT and would leak into the spec files
  # that follow in the same rspec process.
  after do
    conversation_ids = described_class.where(inbox_id: inbox.id).pluck(:id)
    if conversation_ids.any?
      PipelineItem.where(conversation_id: conversation_ids).delete_all
      described_class.where(id: conversation_ids).delete_all
    end
    ContactInbox.where(inbox_id: inbox.id).delete_all
    Contact.where(id: contact.id).delete_all
    Inbox.where(id: inbox.id).delete_all
    Channel::WebWidget.where(id: channel.id).delete_all
  end

  # Every thread takes a connection and only then is released, so they start together
  # instead of in single file.
  def create_conversations_concurrently(count)
    ready = Queue.new
    start = Queue.new
    outcomes = Array.new(count)
    threads = Array.new(count) { |index| creator_thread(index, outcomes, ready, start) }

    # A thread that never gets a connection never signals; an unbounded pop would hang
    # the lane, while join below re-raises the real error.
    count.times { ready.pop(timeout: 30) }
    count.times { start << true }
    threads.each(&:join)

    outcomes.compact.partition { |outcome| outcome.is_a?(Integer) }
  end

  def creator_thread(index, outcomes, ready, start)
    Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ready << true
        start.pop
        outcomes[index] = create_one_conversation
      end
    end
  end

  # Returns the stored display_id, or a description of the error that prevented it.
  def create_one_conversation
    # Mirrors the widget: conversation and message in one BEGIN, which is what decides
    # how long the allocation lock is held.
    ActiveRecord::Base.transaction do
      described_class.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox).display_id
    end
  rescue StandardError => e
    "#{e.class}: #{e.message.lines.first.to_s.strip}"
  end

  describe 'concurrent display_id allocation' do
    it 'gives each simultaneous creation a distinct display_id, without violating the unique index' do
      skip 'connection pool too small to prove concurrency' if concurrency < 2

      display_ids, failures = create_conversations_concurrently(concurrency)

      expect(failures).to be_empty
      expect(display_ids.size).to eq(concurrency)
      expect(display_ids.uniq.size).to eq(concurrency)
    end

    # Covers the `_xact_` choice: a session lock would travel on the connection returned
    # to the pool and block every later conversation creation in the process.
    it 'releases the allocation lock on COMMIT, leaving nothing held on the connection' do
      described_class.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      held_locks = ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_locks WHERE locktype = 'advisory' AND pid = pg_backend_pid()"
      )

      expect(held_locks).to eq(0)
    end
  end
end
