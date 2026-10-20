# frozen_string_literal: true

module ScheduledActions
  class NotificationService
    def self.notify_on_success(scheduled_action)
      new(scheduled_action).notify_on_success
    end

    def self.notify_on_failure(scheduled_action, error = nil)
      new(scheduled_action).notify_on_failure(error)
    end

    def self.notify_on_retry(scheduled_action)
      new(scheduled_action).notify_on_retry
    end

    def initialize(scheduled_action)
      @scheduled_action = scheduled_action
      @notifier = scheduled_action.notifier || scheduled_action.creator
    end

    def notify_on_success
      return if @notifier.blank?

      create_notification(
        notification_type: 'success',
        message: build_success_message
      )
    end

    def notify_on_failure(error = nil)
      return if @notifier.blank?

      create_notification(
        notification_type: 'failure',
        message: build_failure_message(error)
      )
    end

    def notify_on_retry
      return if @notifier.blank?

      create_notification(
        notification_type: 'retry',
        message: build_retry_message
      )
    end

    private

    def create_notification(notification_type:, message:)
      notification = @scheduled_action.notifications.create!(
        user_id: @notifier.id,
        notification_type: notification_type,
        message: message,
        status: 'pending'
      )

      # Queue the notification delivery job
      ScheduledActionNotificationJob.perform_later(notification.id)

      notification
    rescue StandardError => e
      Rails.logger.error("Failed to create notification for scheduled action #{@scheduled_action.id}: #{e.message}")
      nil
    end

    def build_success_message
      action_label = action_type_label(@scheduled_action.action_type)
      target = target_label

      "Ação agendada '#{action_label}' foi executada com sucesso#{target}"
    end

    def build_failure_message(error = nil)
      action_label = action_type_label(@scheduled_action.action_type)
      target = target_label
      error_info = error.present? ? " - #{error}" : ''

      "Ação agendada '#{action_label}' falhou#{target}#{error_info}"
    end

    def build_retry_message
      action_label = action_type_label(@scheduled_action.action_type)
      target = target_label

      "Ação agendada '#{action_label}' será repetida (tentativa #{@scheduled_action.retry_count + 1})#{target}"
    end

    def target_label
      if @scheduled_action.contact_id.present?
        " para #{@scheduled_action.contact&.name || @scheduled_action.contact_id}"
      elsif @scheduled_action.canonical_deal_id.present?
        " para deal #{@scheduled_action.canonical_deal_id}"
      elsif @scheduled_action.conversation_id.present?
        " para conversa #{@scheduled_action.conversation_id}"
      else
        ''
      end
    end

    def action_type_label(action_type)
      labels = {
        'send_message' => 'Enviar Mensagem',
        'send_email' => 'Enviar Email',
        'send_whatsapp' => 'Enviar WhatsApp',
        'send_sms' => 'Enviar SMS',
        'execute_webhook' => 'Executar Webhook',
        'create_task' => 'Criar Tarefa',
        'update_deal_stage' => 'Atualizar Etapa',
        'add_deal_note' => 'Adicionar Nota'
      }

      labels[action_type] || action_type
    end
  end
end
