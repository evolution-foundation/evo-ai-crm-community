# frozen_string_literal: true

require 'net/http'

# Google::DriveService — navega/gerencia arquivos no Google Drive conectado,
# reaproveitando a MESMA conexão OAuth "Google Workspace" já usada por
# GTM/GA4/YouTube/Calendário (Integrations::Hook(app_id: 'google_workspace')) —
# é o mesmo Client ID do Google Cloud, só faltava o escopo `drive` (ver
# Integrations::App#build_google_workspace_action) e este serviço pra
# consumir. Sem app OAuth nem redirect_uri separados.
class Google::DriveService
  TOKEN_URL = 'https://oauth2.googleapis.com/token'
  BASE_URL = 'https://www.googleapis.com/drive/v3'
  UPLOAD_URL = 'https://www.googleapis.com/upload/drive/v3/files'
  FILE_FIELDS = 'id,name,mimeType,iconLink,webViewLink,webContentLink,thumbnailLink,modifiedTime,size,parents'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'google_workspace')
  end

  # Checa o escopo EXATO 'https://www.googleapis.com/auth/drive' (não um
  # include! substring, que também bateria com o antigo 'drive.readonly') —
  # quem só reconectou antes do escopo virar leitura+escrita passa aqui como
  # desconectado e recebe a mensagem certa pra reconectar, em vez de só
  # descobrir que falta permissão quando uma escrita falhar na API do Google.
  def connected?
    return false if @hook&.settings&.dig('refresh_token').blank?

    @hook.settings['scope'].to_s.split.include?('https://www.googleapis.com/auth/drive')
  end

  # Lista pastas/arquivos dentro de `folder_id` (raiz do Drive quando nil),
  # sem os que estão na lixeira. Pastas primeiro, depois arquivos, por nome.
  def list_files(folder_id: nil)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    parent = folder_id.presence || 'root'
    get('/files', token, {
          q: "'#{parent}' in parents and trashed = false",
          fields: "files(#{FILE_FIELDS})",
          orderBy: 'folder,name',
          pageSize: 200
        })
  end

  def create_folder(name:, parent_id: nil)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    body = { name: name, mimeType: 'application/vnd.google-apps.folder' }
    body[:parents] = [parent_id] if parent_id.present?
    post('/files', token, body, fields: FILE_FIELDS)
  end

  def delete_file(file_id:)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    delete("/files/#{file_id}", token)
  end

  def upload_file(name:, content:, content_type:, parent_id: nil)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    metadata = { name: name }
    metadata[:parents] = [parent_id] if parent_id.present?

    uri = URI("#{UPLOAD_URL}?uploadType=multipart&fields=#{FILE_FIELDS}")
    boundary = SecureRandom.hex(16)

    body = +''
    body << "--#{boundary}\r\n"
    body << "Content-Type: application/json; charset=UTF-8\r\n\r\n"
    body << metadata.to_json
    body << "\r\n--#{boundary}\r\n"
    body << "Content-Type: #{content_type}\r\n\r\n"

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = "multipart/related; boundary=#{boundary}"
    request.body = body.b + content.b + "\r\n--#{boundary}--\r\n".b

    handle(http.request(request), 'subir o arquivo pro')
  end

  private

  def not_connected_message
    'Conecte (ou reconecte) o Google em Configurações > Integrações > Google Workspace — precisa aceitar o escopo de Drive.'
  end

  def access_token
    return nil unless connected?

    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'grant_type' => 'refresh_token',
                                      'client_id' => GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_ID', nil),
                                      'client_secret' => GlobalConfigService.load('GOOGLE_OAUTH_CLIENT_SECRET', nil),
                                      'refresh_token' => @hook.settings['refresh_token']
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)['access_token']
  rescue StandardError => e
    Rails.logger.error "Google::DriveService: token refresh error: #{e.message}"
    nil
  end

  def get(path, token, params)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(params)

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Get.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"

    handle(http.request(request), 'consultar o')
  end

  def post(path, token, body, fields: nil)
    uri = URI("#{BASE_URL}#{path}")
    uri.query = URI.encode_www_form(fields: fields) if fields

    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    handle(http.request(request), 'gravar no')
  end

  def delete(path, token)
    uri = URI("#{BASE_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Delete.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"

    response = http.request(request)
    if response.code.to_i.between?(200, 299)
      Result.new(success: true, data: {})
    else
      parsed = JSON.parse(response.body) rescue {}
      Result.new(success: false, error: parsed.dig('error', 'message') || 'Falha ao excluir no Google Drive.')
    end
  rescue StandardError => e
    Rails.logger.error "Google::DriveService: delete error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao excluir no Google Drive.')
  end

  def handle(response, verb)
    parsed = response.body.present? ? JSON.parse(response.body) : {}

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Google::DriveService: #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed.dig('error', 'message') || "Falha ao #{verb} Google Drive.")
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Google::DriveService: error: #{e.message}"
    Result.new(success: false, error: "Erro inesperado ao #{verb} Google Drive.")
  end
end
