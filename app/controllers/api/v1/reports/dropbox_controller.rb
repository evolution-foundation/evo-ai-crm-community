# frozen_string_literal: true

# Endpoint único (despacha por `acao`) atrás da aba "Dropbox" do menu
# principal — navega, cria pastas, sobe e exclui arquivos na conta Dropbox
# conectada em Configurações > Integrações > Dropbox (Dropbox::FilesService).
class Api::V1::Reports::DropboxController < Api::V1::BaseController
  def handle
    service = Dropbox::FilesService.new

    case params[:acao]
    when 'status'
      render json: { success: true, data: { connected: service.connected? } }
    when 'listar_arquivos'
      respond(service.list_folder(path: params[:path].presence || ''))
    when 'criar_pasta'
      respond(service.create_folder(path: params.require(:path)))
    when 'excluir_arquivo'
      respond(service.delete(path: params.require(:path)))
    when 'link_temporario'
      respond(service.temporary_link(path: params.require(:path)))
    when 'subir_arquivo'
      file = params.require(:file)
      respond(service.upload(path: "#{params[:folder_path].presence}/#{file.original_filename}", content: file.read))
    else
      error_response(ApiErrorCodes::MISSING_REQUIRED_FIELD, "Ação desconhecida: #{params[:acao]}", status: :unprocessable_entity)
    end
  end

  private

  def respond(result)
    if result.success
      render json: { success: true, data: result.data }
    else
      error_response(ApiErrorCodes::EXTERNAL_SERVICE_ERROR, result.error, status: :bad_gateway)
    end
  end
end
