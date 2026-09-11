# Troca o code do OAuth do Dropbox (fluxo iniciado em Integrations::App#action)
# pelos tokens e guarda num Integrations::Hook (app_id: 'dropbox') — mesmo
# padrão do GoogleWorkspaceAuthorizationsController, mas com o app OAuth
# próprio do Dropbox (DROPBOX_APP_KEY/SECRET em GlobalConfig).
class Api::V1::Integrations::DropboxAuthorizationsController < Api::V1::BaseController
  include Dropbox::IntegrationHelper

  TOKEN_URL = 'https://api.dropboxapi.com/oauth2/token'
  ACCOUNT_URL = 'https://api.dropboxapi.com/2/users/get_current_account'

  def callback
    code = params[:code]
    state = params[:state]
    return error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, 'Código ou state ausente') unless code && state

    unless verify_dropbox_token(state) == 'dropbox'
      return error_response(ApiErrorCodes::INVALID_SIGNATURE, 'State inválido ou expirado', status: :unauthorized)
    end

    token_data = exchange_code(code)
    return error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível obter o token do Dropbox.', status: :bad_gateway) unless token_data

    email = fetch_email(token_data['access_token'])
    save_hook(token_data, email)

    success_response(data: { email: email })
  rescue StandardError => e
    Rails.logger.error("DropboxAuthorizationsController: #{e.message}")
    Rails.logger.error(e.backtrace.join("\n"))
    error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, 'Não foi possível concluir a autorização com o Dropbox.')
  end

  private

  def redirect_uri
    Integrations::App.dropbox_integration_url
  end

  def exchange_code(code)
    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'code' => code,
                                      'grant_type' => 'authorization_code',
                                      'client_id' => GlobalConfigService.load('DROPBOX_APP_KEY', nil),
                                      'client_secret' => GlobalConfigService.load('DROPBOX_APP_SECRET', nil),
                                      'redirect_uri' => redirect_uri
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)
  end

  def fetch_email(access_token)
    return nil if access_token.blank?

    uri = URI(ACCOUNT_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{access_token}"
    request['Content-Type'] = 'application/json'
    response = http.request(request)
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body).dig('email')
  rescue StandardError
    nil
  end

  def save_hook(token_data, email)
    hook = Integrations::Hook.find_or_initialize_by(app_id: 'dropbox')
    existing_settings = hook.settings || {}
    hook.settings = existing_settings.merge(
      'email' => email,
      'access_token' => token_data['access_token'],
      # O Dropbox só devolve refresh_token no primeiro consentimento
      # (token_access_type=offline); preserva o anterior numa reautorização.
      'refresh_token' => token_data['refresh_token'] || existing_settings['refresh_token'],
      'expires_on' => (Time.current.utc + token_data['expires_in'].to_i.seconds).to_s
    )
    hook.save!
  end
end
