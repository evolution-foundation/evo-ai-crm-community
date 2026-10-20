# frozen_string_literal: true

class Instagram::FetchContactAvatarJob < ApplicationJob
  queue_as :low

  TransientProfileError = Class.new(StandardError)

  retry_on Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, wait: :polynomially_longer, attempts: 5
  retry_on HTTParty::Error, wait: :polynomially_longer, attempts: 3
  retry_on TransientProfileError, wait: :polynomially_longer, attempts: 5

  def perform(contact_inbox_id)
    contact_inbox = find_contact_inbox(contact_inbox_id)
    return unless avatar_missing_from_instagram_contact?(contact_inbox)

    response = Instagram::ContactProfileFetcher.new(inbox: contact_inbox.inbox).call(contact_inbox.source_id)
    raise TransientProfileError, "Instagram profile HTTP #{response.code}" if retryable_response?(response)

    return log_unavailable_profile(response) unless response.success?

    avatar_url = avatar_url_from(response)
    Avatar::AvatarFromUrlJob.perform_later(contact_inbox.contact, avatar_url) if avatar_url
  rescue JSON::ParserError => e
    Rails.logger.warn("[Instagram::FetchContactAvatarJob] Invalid profile response: #{e.message}")
  end

  private

  def find_contact_inbox(contact_inbox_id)
    ContactInbox.includes(:inbox, contact: :avatar_attachment).find_by(id: contact_inbox_id)
  end

  def avatar_missing_from_instagram_contact?(contact_inbox)
    contact_inbox&.inbox&.instagram? && !contact_inbox.contact.avatar.attached?
  end

  def retryable_response?(response)
    response.code.to_i == 429 || response.code.to_i >= 500
  end

  def log_unavailable_profile(response)
    Rails.logger.warn("[Instagram::FetchContactAvatarJob] Profile request failed with HTTP #{response.code}")
  end

  def avatar_url_from(response)
    profile = JSON.parse(response.body)
    profile['profile_pic'].presence || profile['profile_picture_url'].presence
  end
end
