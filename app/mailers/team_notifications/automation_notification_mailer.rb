class TeamNotifications::AutomationNotificationMailer < ApplicationMailer
  include FrontendUrlsHelper

  def conversation_creation(conversation, team, message)
    return unless smtp_config_set_or_development?

    @agents = team.team_members
    @conversation = conversation
    @custom_message = message
    @action_url = frontend_url("conversations/#{@conversation.id}")

    send_an_email_to_team
  end

  private

  def send_an_email_to_team
    subject = 'This email has been sent via automation rule actions.'
    @action_url = frontend_url("conversations/#{@conversation.id}")
    @agent_emails = @agents.collect(&:user).pluck(:email)
    send_mail_with_liquid(to: @agent_emails, subject: subject) and return
  end

  def liquid_droppables
    super.merge!({
                   conversation: @conversation,
                   inbox: @conversation.inbox
                 })
  end

  def liquid_locals
    super.merge!({
                   custom_message: @custom_message
                 })
  end
end
