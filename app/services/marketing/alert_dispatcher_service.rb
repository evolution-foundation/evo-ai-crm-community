# Ponto único de saída pros avisos automáticos de Marketing (relatório
# semanal + checagem diária de metas) — lê quais canais estão habilitados em
# MARKETING_ALERTS_CHANNELS (Marketing > Alertas e Relatórios) e distribui
# pra cada um. Cada canal falha isoladamente (ex: WhatsApp não configurado
# não impede o e-mail de sair).
module Marketing
  class AlertDispatcherService
    def self.call(kind:, title:, body:)
      new(kind: kind, title: title, body: body).call
    end

    def initialize(kind:, title:, body:)
      @kind = kind
      @title = title
      @body = body
    end

    def call
      channels = enabled_channels
      return if channels.empty?

      MarketingAlert.create!(kind: @kind, title: @title, body: @body) if channels.include?('notification')
      send_whatsapp if channels.include?('whatsapp')
      send_email if channels.include?('email')
    end

    private

    def enabled_channels
      GlobalConfigService.load('MARKETING_ALERTS_CHANNELS', '').to_s.split(',').map(&:strip)
    end

    def send_whatsapp
      result = Marketing::WhatsappNotifierService.new(title: @title, body: @body).call
      Rails.logger.warn("Marketing::AlertDispatcherService: WhatsApp não enviado (#{result.error})") unless result.success
    end

    def send_email
      email = GlobalConfigService.load('MARKETING_ALERTS_EMAIL', nil)
      return Rails.logger.warn('Marketing::AlertDispatcherService: e-mail habilitado mas MARKETING_ALERTS_EMAIL não configurado') if email.blank?

      MarketingAlertMailer.notify(email, @title, @body).deliver_later
    rescue StandardError => e
      Rails.logger.error("Marketing::AlertDispatcherService email failed: #{e.class}: #{e.message}")
    end
  end
end
