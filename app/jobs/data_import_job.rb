# TODO: logic is written tailored to contact import since its the only import available
# let's break this logic and clean this up in future

class DataImportJob < ApplicationJob
  queue_as :low
  retry_on ActiveStorage::FileNotFoundError, wait: 1.minute, attempts: 3

  def perform(data_import)
    @data_import = data_import
    @contact_manager = DataImport::ContactManager.new
    begin
      process_import_file
      send_import_notification_to_admin
    rescue CSV::MalformedCSVError => e
      handle_csv_error(e)
    end
  end

  private

  def process_import_file
    @data_import.update!(status: :processing)

    # Separar contatos por tipo
    person_rows, company_rows, rejected_contacts = parse_csv_and_classify_contacts

    # Primeiro importar empresas (necessário para vínculos)
    import_companies(company_rows)

    # Depois importar pessoas
    import_persons(person_rows)

    # Processar vínculos entre pessoas e empresas
    process_company_linkages(person_rows)

    total_imported = company_rows.length + person_rows.length
    update_data_import_status(total_imported, rejected_contacts.length)
    save_failed_records_csv(rejected_contacts)
  end

  def parse_csv_and_classify_contacts
    person_rows = []
    company_rows = []
    rejected_contacts = []

    # Ensuring that importing non utf-8 characters will not throw error
    data = @data_import.import_file.download
    utf8_data = data.force_encoding('UTF-8')

    # Ensure that the data is valid UTF-8, preserving valid characters
    clean_data = utf8_data.valid_encoding? ? utf8_data : utf8_data.encode('UTF-16le', invalid: :replace, replace: '').encode('UTF-8')

    csv = CSV.parse(clean_data, headers: true)

    csv.each do |row|
      params = row.to_h.with_indifferent_access
      tipo = params[:tipo] || params[:type] || 'person'

      if tipo == 'company'
        current_contact = @contact_manager.build_contact(params)
        if current_contact.valid?
          company_rows << { row: params, contact: current_contact }
        else
          append_rejected_contact(row, current_contact, rejected_contacts)
        end
      else
        current_contact = @contact_manager.build_contact(params)
        if current_contact.valid?
          person_rows << { row: params, contact: current_contact }
        else
          append_rejected_contact(row, current_contact, rejected_contacts)
        end
      end
    end

    [person_rows, company_rows, rejected_contacts]
  end

  def append_rejected_contact(row, contact, rejected_contacts)
    row['errors'] = contact.errors.full_messages.join(', ')
    rejected_contacts << row
  end

  def import_contacts(contacts)
    # <struct ActiveRecord::Import::Result failed_instances=[], num_inserts=1, ids=[444, 445], results=[]>
    Contact.import(contacts, synchronize: contacts, on_duplicate_key_ignore: true, track_validation_failures: true, validate: true, batch_size: 1000)
  end

  def import_companies(company_rows)
    return if company_rows.empty?

    companies = company_rows.map { |row_data| row_data[:contact] }
    Contact.import(companies, synchronize: companies, on_duplicate_key_ignore: true, track_validation_failures: true, validate: true, batch_size: 1000)
  end

  def import_persons(person_rows)
    return if person_rows.empty?

    persons = person_rows.map { |row_data| row_data[:contact] }
    Contact.import(persons, synchronize: persons, on_duplicate_key_ignore: true, track_validation_failures: true, validate: true, batch_size: 1000)
  end

  def process_company_linkages(person_rows)
    person_rows.each do |person_data|
      empresas_vinculadas = person_data[:row][:empresas_vinculadas]
      next unless empresas_vinculadas.present?

      contact = person_data[:contact]
      company_names = empresas_vinculadas.split('|').map(&:strip)

      company_names.each do |company_name|
        company = Contact.companies.find_by("LOWER(name) = ?", company_name.downcase)
        if company
          contact.add_company(company)
        else
          # Criar nova empresa se não existir
          new_company = Contact.create!(
            type: 'company',
            name: company_name,
            email: nil,
            phone_number: nil
          )
          contact.add_company(new_company)
        end
      end
    end
  end

  def update_data_import_status(processed_records, rejected_records)
    @data_import.update!(status: :completed, processed_records: processed_records, total_records: processed_records + rejected_records)
  end

  def save_failed_records_csv(rejected_contacts)
    csv_data = generate_csv_data(rejected_contacts)
    return if csv_data.blank?

    @data_import.failed_records.attach(io: StringIO.new(csv_data), filename: "#{Time.zone.today.strftime('%Y%m%d')}_contacts.csv",
                                       content_type: 'text/csv')
    send_import_notification_to_admin
  end

  def generate_csv_data(rejected_contacts)
    headers = CSV.parse(@data_import.import_file.download, headers: true).headers
    headers << 'errors'
    return if rejected_contacts.blank?

    CSV.generate do |csv|
      csv << headers
      rejected_contacts.each do |record|
        csv << record
      end
    end
  end

  def handle_csv_error(error) # rubocop:disable Lint/UnusedMethodArgument
    @data_import.update!(status: :failed)
    send_import_failed_notification_to_admin
  end

  def send_import_notification_to_admin
    AdministratorNotifications::AccountNotificationMailer.with(account: nil).contact_import_complete(@data_import).deliver_later
  end

  def send_import_failed_notification_to_admin
    AdministratorNotifications::AccountNotificationMailer.with(account: nil).contact_import_failed.deliver_later
  end
end
