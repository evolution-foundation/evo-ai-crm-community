# frozen_string_literal: true

require 'rails_helper'
require_relative '../../db/migrate/20260914120000_drop_mentions_table'

# `db:prepare` loads schema.rb and never runs this migration, so without this
# spec both branches ship unexecuted. The RLS branch matters more than it looks:
# the enterprise overlay puts FORCE row-level security on `notifications`, and a
# role that does not bypass it deletes zero rows while reporting success.
RSpec.describe DropMentionsTable, type: :migration do
  let(:verbose) { false }
  let(:migration) { described_class.new.tap { |m| m.verbose = verbose } }
  let(:connection) { ActiveRecord::Base.connection }
  let(:orphan_type) { described_class::ORPHAN_NOTIFICATION_TYPE }

  # schema.rb no longer carries the table; `down` is how the test gets it back.
  before { described_class.new.tap { |m| m.verbose = false }.down }

  def mentions_table?
    connection.select_value("SELECT to_regclass('public.mentions') IS NOT NULL")
  end

  def insert_notification(type)
    connection.execute(<<~SQL.squish)
      INSERT INTO notifications
        (id, user_id, notification_type, primary_actor_type, primary_actor_id, created_at, updated_at)
      VALUES
        (gen_random_uuid(), gen_random_uuid(), #{type}, 'Conversation', gen_random_uuid(), now(), now())
    SQL
  end

  def notification_count(type)
    connection.select_value("SELECT count(*) FROM notifications WHERE notification_type = #{type}").to_i
  end

  describe '#up' do
    it 'drops the table' do
      expect { migration.up }.to change { mentions_table? }.from(true).to(false)
    end

    it 'deletes the orphaned conversation_mention notifications' do
      2.times { insert_notification(orphan_type) }

      expect { migration.up }.to change { notification_count(orphan_type) }.from(2).to(0)
    end

    it 'leaves every other notification type alone' do
      assignment = Notification::NOTIFICATION_TYPES[:conversation_assignment]
      insert_notification(assignment)

      expect { migration.up }.not_to(change { notification_count(assignment) })
    end
  end

  describe '#up reporting' do
    let(:verbose) { true }

    it 'reports the rows it discarded instead of swallowing them' do
      connection.execute(<<~SQL.squish)
        INSERT INTO mentions (id, user_id, conversation_id, mentioned_at, created_at, updated_at)
        VALUES (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), now(), now(), now())
      SQL

      expect { migration.up }.to output(/mentions: 1 row\(s\) discarded/).to_stdout
    end

    it 'reports the orphaned notifications it deleted' do
      insert_notification(orphan_type)

      expect { migration.up }.to output(/notifications type #{orphan_type} .+: 1 deleted/).to_stdout
    end

    it 'warns that its own counts are partial when row-level security filters the role' do
      allow(migration).to receive(:row_security_active?).and_return(true)

      expect { migration.up }.to output(/WARNING: row-level security filters mentions, notifications/).to_stdout
    end

    it 'says nothing about rows or RLS when the role reads both tables clean and unfiltered' do
      expect { migration.up }.not_to output(/discarded|deleted|WARNING/).to_stdout
    end

    it 'sees no row-level security on this schema (control for the stub above)' do
      expect(migration.send(:row_security_active?, :notifications)).to be(false)
    end
  end

  describe '#down' do
    it 'restores the table with its three indexes' do
      migration.up
      migration.down

      expect(connection.indexes('mentions').map(&:name)).to contain_exactly(
        'index_mentions_on_conversation_id',
        'index_mentions_on_user_id',
        'index_mentions_on_user_id_and_conversation_id'
      )
    end

    it 'does not restore the notifications `up` deleted (documented limit)' do
      insert_notification(orphan_type)
      migration.up
      migration.down

      expect(notification_count(orphan_type)).to eq(0)
    end
  end
end
