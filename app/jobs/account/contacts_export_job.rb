class Account::ContactsExportJob < ApplicationJob
  queue_as :low

  PII_MASKERS = {
    'email' => :mask_email, 'phone_number' => :mask_phone, 'identifier' => :mask_identifier, 'name' => :mask_phone_like_name
  }.freeze
  # A cell a spreadsheet would run as a formula; a leading + or - followed only by phone characters is data.
  FORMULA_START = /\A(?:[=@\t\r]|[+-](?![\d\s().*-]*\z))/

  def perform(user_id, column_names, params)
    @params = params
    @user = User.find(user_id)

    headers = valid_headers(column_names)
    csv_data = generate_csv(headers)
    send_mail_with_attachment(csv_data)
  end

  private

  def generate_csv(headers)
    mask = mask_pii?
    CSV.generate do |csv|
      csv << headers
      contacts.each do |contact|
        csv << headers.map { |header| csv_cell(contact, header, mask) }
      end
    end
  end

  def csv_cell(contact, header, mask)
    value = contact.send(header)
    value = ContactPiiMasker.public_send(PII_MASKERS[header], value) if mask && PII_MASKERS.key?(header)
    value.is_a?(String) && value.match?(FORMULA_START) ? "'#{value}" : value
  end

  # Same rule as the API serializers: with the account flag on, only admins see raw contact PII.
  def mask_pii?
    ContactPiiMasker.account_flag_enabled? && !@user.administrator?
  end

  def contacts
    if @params.present? && @params[:payload].present? && @params[:payload].any?
      result = ::Contacts::FilterService.new(nil, @user, @params).perform
      result[:contacts]
    elsif @params[:label].present?
      Contact.resolved_contacts.tagged_with(@params[:label], any: true)
    else
      Contact.resolved_contacts
    end
  end

  def valid_headers(column_names)
    (column_names.presence || default_columns) & Contact.column_names
  end

  def send_mail_with_attachment(csv_data)
    return if csv_data.blank?

    mailer = AdministratorNotifications::AccountNotificationMailer.with({})
    mailer.contact_export_complete_with_data(csv_data, @user.email)&.deliver_now
  end

  def default_columns
    %w[id name email phone_number]
  end
end
