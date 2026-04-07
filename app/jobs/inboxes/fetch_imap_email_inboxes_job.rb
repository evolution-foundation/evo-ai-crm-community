class Inboxes::FetchImapEmailInboxesJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    email_inboxes = Inbox.where(channel_type: 'Channel::Email')
    fetched_count = 0
    skipped_push_count = 0
    skipped_gmail_count = 0

    email_inboxes.find_each(batch_size: 100) do |inbox|
      if should_fetch_emails?(inbox)
        ::Inboxes::FetchImapEmailsJob.perform_later(inbox.channel)
        fetched_count += 1
      elsif inbox.channel.use_push_notifications?
        skipped_push_count += 1
      elsif inbox.channel.google?
        skipped_gmail_count += 1
      end
    end

    if skipped_gmail_count > 0
      Rails.logger.info "[IMAP_FETCH] Scheduled #{fetched_count} IMAP fetches, skipped #{skipped_push_count} push-enabled channels, skipped #{skipped_gmail_count} Gmail channels (using push)"
    else
      Rails.logger.info "[IMAP_FETCH] Scheduled #{fetched_count} IMAP fetches, skipped #{skipped_push_count} push-enabled channels"
    end
  end

  private

  def should_fetch_emails?(inbox)
    return false if inbox.channel.use_push_notifications?
    # Skip Gmail channels (always use push)
    return false if inbox.channel.google?

    inbox.channel.imap_enabled
  end
end
