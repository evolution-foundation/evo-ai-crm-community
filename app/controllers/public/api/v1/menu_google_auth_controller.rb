# frozen_string_literal: true

require 'googleauth/id_tokens'

# "Login with Google" on the public digital-menu checkout. Verifies the
# Google ID token client-side sign-in produced, then looks up a matching
# Contact (by email) and the customer's most recent WorkOrder (for address —
# Contact itself has no address fields) so the checkout form can prefill
# whatever the CRM already knows, still fully editable by the customer.
class Public::Api::V1::MenuGoogleAuthController < PublicController
  def login
    client_id = GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil)
    if client_id.blank?
      return render json: { success: false, error: 'Login com Google não está configurado.' }, status: :unprocessable_entity
    end

    payload = verify_credential(params[:credential], client_id)
    if payload.nil? || payload['email_verified'] != true
      return render json: { success: false, error: 'Token do Google inválido ou expirado.' }, status: :unauthorized
    end

    email = payload['email']
    contact = Contact.find_by(email: email)
    last_order = WorkOrder.where(client_email: email).order(created_at: :desc).first

    render json: {
      success: true,
      data: {
        found: contact.present? || last_order.present?,
        email: email,
        full_name: contact&.name.presence || last_order&.client_name.presence || payload['name'],
        cpf: contact&.tax_id.presence || last_order&.client_cpf,
        phone: contact&.phone_number.presence || last_order&.client_phone,
        instagram: last_order&.client_instagram,
        zip: last_order&.client_cep,
        address: last_order&.client_address,
        number: last_order&.client_number,
        neighborhood: last_order&.client_neighborhood,
        city: last_order&.client_city,
        state: last_order&.client_state
      }
    }
  end

  private

  def verify_credential(credential, client_id)
    return nil if credential.blank?

    Google::Auth::IDTokens.verify_oidc(credential, aud: client_id)
  rescue Google::Auth::IDTokens::VerificationError => e
    Rails.logger.warn "MenuGoogleAuthController: Google ID token rejected: #{e.message}"
    nil
  end
end
