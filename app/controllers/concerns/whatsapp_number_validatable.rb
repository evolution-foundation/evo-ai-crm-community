# Blocks creating/attaching a WhatsApp contact_inbox for a number that the
# provider confirms is not registered on WhatsApp, so the agent gets an
# immediate error instead of a silent async "Falha no envio" later on
# SendReplyJob. Only applies to the manual/agent-initiated flows that include
# this concern -- webhook-created contacts never go through it, so inbound
# processing is unaffected. A nil check result (provider doesn't support it,
# e.g. whatsapp_cloud/360dialog/notificame, or the check itself failed) lets
# the request proceed -- we never block on an inconclusive answer.
module WhatsappNumberValidatable
  extend ActiveSupport::Concern

  private

  def render_whatsapp_number_unreachable_error(inbox:, phone_number:)
    return false unless inbox&.whatsapp?
    return false if phone_number.blank?

    exists = inbox.channel.check_whatsapp_number_exists?(phone_number)
    return false if exists.nil? || exists

    error_response(
      ApiErrorCodes::WHATSAPP_API_ERROR,
      'This phone number does not appear to be registered on WhatsApp',
      details: { field: 'phone_number', phone_number: phone_number },
      status: :unprocessable_content
    )
    true
  end
end
