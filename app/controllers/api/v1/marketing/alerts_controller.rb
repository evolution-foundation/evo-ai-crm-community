# Histórico dos avisos automáticos de Marketing (relatório semanal +
# checagem diária) — só existe uma linha aqui quando o canal "notification"
# está habilitado em Marketing > Alertas e Relatórios (ver
# Marketing::AlertDispatcherService).
module Api
  module V1
    module Marketing
      class AlertsController < Api::V1::BaseController
        def index
          alerts = MarketingAlert.recent_first.limit(50)
          render json: { success: true, data: alerts.map { |a| serialize(a) } }
        end

        def mark_read
          alert = MarketingAlert.find(params[:id])
          alert.update!(read_at: Time.current) if alert.read_at.nil?
          render json: { success: true, data: serialize(alert) }
        rescue ActiveRecord::RecordNotFound
          render json: { success: false, errors: ['Não encontrado'] }, status: :not_found
        end

        private

        def serialize(alert)
          {
            id: alert.id,
            kind: alert.kind,
            title: alert.title,
            body: alert.body,
            read_at: alert.read_at&.iso8601,
            created_at: alert.created_at.iso8601
          }
        end
      end
    end
  end
end
