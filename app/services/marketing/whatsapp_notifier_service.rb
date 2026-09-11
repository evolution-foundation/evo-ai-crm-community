# Envia um aviso de Marketing (relatório semanal / checagem diária) pro
# WhatsApp configurado em Marketing > Alertas e Relatórios
# (MARKETING_ALERTS_INBOX_ID = canal que envia, MARKETING_ALERTS_WHATSAPP_NUMBER
# = número que recebe). Reaproveita a mesma infraestrutura de contato/
# conversa/mensagem usada pelo resto do CRM (ContactInboxWithContactBuilder +
# ConversationBuilder — mesmo padrão de DigitalMenu::OrderNotificationService),
# então o envio de fato passa pelos providers já existentes (Evolution/Z-API/
# Cloud/etc) sem reinventar a integração com WhatsApp.
module Marketing
  class WhatsappNotifierService
    Result = Struct.new(:success, :error, keyword_init: true)

    CONTACT_NAME = 'Alertas de Marketing'

    def initialize(title:, body:)
      @title = title
      @body = body
    end

    def call
      inbox_id = GlobalConfigService.load('MARKETING_ALERTS_INBOX_ID', nil)
      target_phone = GlobalConfigService.load('MARKETING_ALERTS_WHATSAPP_NUMBER', nil)
      return Result.new(success: false, error: 'not_configured') if inbox_id.blank? || target_phone.blank?

      inbox = Inbox.find_by(id: inbox_id)
      return Result.new(success: false, error: 'inbox_not_found') unless inbox

      contact_inbox = ContactInboxWithContactBuilder.new(
        inbox: inbox,
        contact_attributes: { phone_number: normalize_phone(target_phone), name: CONTACT_NAME }
      ).perform
      return Result.new(success: false, error: 'contact_error') unless contact_inbox

      conversation = ConversationBuilder.new(
        params: ActionController::Parameters.new({}).permit!,
        contact_inbox: contact_inbox
      ).perform

      conversation.messages.create!(
        inbox_id: conversation.inbox_id,
        message_type: :outgoing,
        content: "*#{@title}*\n\n#{@body}"
      )

      Result.new(success: true)
    rescue StandardError => e
      Rails.logger.error("Marketing::WhatsappNotifierService failed: #{e.class}: #{e.message}")
      Result.new(success: false, error: e.message)
    end

    private

    def normalize_phone(phone)
      digits = phone.to_s.gsub(/\D/, '')
      digits = "55#{digits}" unless digits.start_with?('55')
      "+#{digits}"
    end
  end
end
