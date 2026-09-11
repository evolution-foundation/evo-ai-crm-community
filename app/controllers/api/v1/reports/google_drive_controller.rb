# frozen_string_literal: true

# Endpoint único (despacha por `acao`) atrás da aba "Drive" do menu principal —
# navega, cria pastas, sobe e exclui arquivos no Google Drive conectado em
# Configurações > Integrações > Google Workspace (Google::DriveService).
class Api::V1::Reports::GoogleDriveController < Api::V1::BaseController
  def handle
    service = Google::DriveService.new

    case params[:acao]
    when 'status'
      render json: { success: true, data: { connected: service.connected? } }
    when 'listar_arquivos'
      respond(service.list_files(folder_id: params[:folder_id].presence))
    when 'criar_pasta'
      respond(service.create_folder(name: params.require(:name), parent_id: params[:parent_id].presence))
    when 'excluir_arquivo'
      respond(service.delete_file(file_id: params.require(:file_id)))
    when 'subir_arquivo'
      file = params.require(:file)
      respond(service.upload_file(
                name: file.original_filename,
                content: file.read,
                content_type: file.content_type.presence || 'application/octet-stream',
                parent_id: params[:parent_id].presence
              ))
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
