# frozen_string_literal: true

# Schedules a contact's WhatsApp profile picture fetch on the Evolution API
# inbound flow. Mirrors Whatsapp::EvolutionGoHandlers::ProfilePictureHandler so
# that any provider with proactive avatar fetching follows the same pattern.
module Whatsapp::EvolutionHandlers::ProfilePictureHandler
  include Whatsapp::EvolutionHandlers::Helpers

  private

  def update_contact_profile_picture(contact, phone_number)
    return if contact.blank?
    return if contact.avatar.attached?
    return if phone_number.blank?

    channel = inbox&.channel
    return unless channel

    Rails.logger.info "Evolution API: Scheduling avatar fetch for contact #{contact.id} (number: #{phone_number})"

    Evolution::FetchContactAvatarJob.perform_later(contact.id, phone_number, channel.id)
  rescue StandardError => e
    Rails.logger.error "Evolution API: Failed to schedule avatar fetch for contact #{contact.id}: #{e.message}"
  end
end
