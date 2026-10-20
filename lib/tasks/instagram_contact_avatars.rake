# frozen_string_literal: true

namespace :instagram do
  desc 'Enqueue an idempotent backfill of missing Instagram contact avatars'
  task backfill_contact_avatars: :environment do
    Inbox.where(channel_type: 'Channel::Instagram').find_each do |inbox|
      Instagram::BackfillContactAvatarsJob.perform_later(inbox.id)
    end
  end
end
