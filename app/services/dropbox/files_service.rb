# frozen_string_literal: true

require 'net/http'

# Dropbox::FilesService — navega/gerencia arquivos na conta Dropbox conectada
# em Configurações > Integrações > Dropbox (Integrations::Hook(app_id:
# 'dropbox')). Exige seu próprio app OAuth (DROPBOX_APP_KEY/SECRET), sem
# reaproveitar nenhuma conexão Google — são provedores diferentes.
class Dropbox::FilesService
  TOKEN_URL = 'https://api.dropboxapi.com/oauth2/token'
  API_URL = 'https://api.dropboxapi.com/2'
  CONTENT_URL = 'https://content.dropboxapi.com/2'

  Result = Struct.new(:success, :data, :error, keyword_init: true)

  def initialize
    @hook = Integrations::Hook.account_hooks.find_by(app_id: 'dropbox')
  end

  def connected?
    @hook&.settings&.dig('refresh_token').present?
  end

  # path: '' lista a raiz. Dropbox usa path SEM barra final e "" (não "/")
  # pra raiz — normaliza aqui pra API de listagem não confundir o front.
  def list_folder(path: '')
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    post('/files/list_folder', token, { path: normalize_path(path), limit: 200 })
  end

  def create_folder(path:)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    post('/files/create_folder_v2', token, { path: normalize_path(path) })
  end

  def delete(path:)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    post('/files/delete_v2', token, { path: normalize_path(path) })
  end

  # Link temporário (4h) pra baixar/visualizar um arquivo específico — usado
  # pelo front pra abrir o arquivo numa aba nova em vez de reimplementar
  # preview de cada tipo de arquivo.
  def temporary_link(path:)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    post('/files/get_temporary_link', token, { path: normalize_path(path) })
  end

  def upload(path:, content:)
    token = access_token
    return Result.new(success: false, error: not_connected_message) unless token

    uri = URI("#{CONTENT_URL}/files/upload")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 120

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/octet-stream'
    request['Dropbox-API-Arg'] = { path: normalize_path(path), mode: 'add', autorename: true }.to_json
    request.body = content.b

    handle(http.request(request))
  end

  private

  def normalize_path(path)
    return '' if path.blank? || path == '/'

    path.start_with?('/') ? path : "/#{path}"
  end

  def not_connected_message
    'Conecte o Dropbox em Configurações > Integrações > Dropbox.'
  end

  def access_token
    return nil unless connected?

    response = Net::HTTP.post_form(URI(TOKEN_URL), {
                                      'grant_type' => 'refresh_token',
                                      'client_id' => GlobalConfigService.load('DROPBOX_APP_KEY', nil),
                                      'client_secret' => GlobalConfigService.load('DROPBOX_APP_SECRET', nil),
                                      'refresh_token' => @hook.settings['refresh_token']
                                    })
    return nil unless response.code.to_i.between?(200, 299)

    JSON.parse(response.body)['access_token']
  rescue StandardError => e
    Rails.logger.error "Dropbox::FilesService: token refresh error: #{e.message}"
    nil
  end

  def post(path, token, body)
    uri = URI("#{API_URL}#{path}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    request = Net::HTTP::Post.new(uri.request_uri)
    request['Authorization'] = "Bearer #{token}"
    request['Content-Type'] = 'application/json'
    request.body = body.to_json

    handle(http.request(request))
  end

  def handle(response)
    parsed = response.body.present? ? JSON.parse(response.body) : {}

    unless response.code.to_i.between?(200, 299)
      Rails.logger.error "Dropbox::FilesService: #{response.code} #{response.body}"
      return Result.new(success: false, error: parsed['error_summary'] || 'Falha ao consultar o Dropbox.')
    end

    Result.new(success: true, data: parsed)
  rescue StandardError => e
    Rails.logger.error "Dropbox::FilesService: error: #{e.message}"
    Result.new(success: false, error: 'Erro inesperado ao consultar o Dropbox.')
  end
end
