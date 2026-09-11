class MarketingAlertMailer < ApplicationMailer
  def notify(to_email, title, body)
    @title = title
    @body = body

    mail(to: to_email, subject: title)
  end
end
