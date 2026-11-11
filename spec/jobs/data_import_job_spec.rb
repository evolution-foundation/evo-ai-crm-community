# frozen_string_literal: true

require 'rails_helper'

RSpec.describe DataImportJob, type: :job do
  let!(:contact) { Contact.create!(name: 'Maria', identifier: "cust-#{SecureRandom.hex(4)}") }

  let(:csv_body) do
    [
      'conversation_external_id,contact_identifier,message_content,direction,sent_at,sender_name,message_type,message_external_id',
      "conv-j1,#{contact.identifier},Hi,incoming,2026-01-15T10:30:00Z,,text,msg-j1"
    ].join("\n")
  end

  it 'dispatches conversation flow when data_type=conversations' do
    data_import = DataImport.create!(data_type: 'conversations')
    data_import.import_file.attach(io: StringIO.new(csv_body), filename: 'c.csv', content_type: 'text/csv')

    described_class.new.perform(data_import)

    data_import.reload
    expect(data_import.status).to eq('completed')
    expect(data_import.total_records).to eq(1)
    expect(data_import.processed_records).to eq(1)
    report = JSON.parse(data_import.processing_errors)
    expect(report['success_count']).to eq(1)
    expect(report['errors']).to eq([])
    expect(Conversation.find_by(identifier: 'conv-j1')).to be_present
  end

  it 'attaches failed_records CSV when rows are rejected' do
    csv = [
      'conversation_external_id,contact_identifier,message_content,direction,sent_at,sender_name,message_type,message_external_id',
      'conv-j2,unknown-id,Hi,incoming,2026-01-15T10:30:00Z,,text,msg-j2'
    ].join("\n")
    data_import = DataImport.create!(data_type: 'conversations')
    data_import.import_file.attach(io: StringIO.new(csv), filename: 'c.csv', content_type: 'text/csv')

    described_class.new.perform(data_import)

    data_import.reload
    expect(data_import.failed_records).to be_attached
    body = data_import.failed_records.download
    expect(body).to include('errors')
    expect(body).to include('contact not found')
  end

  it 'marks status as failed when CSV is malformed' do
    data_import = DataImport.create!(data_type: 'conversations')
    data_import.import_file.attach(io: StringIO.new("just,one\n"), filename: 'c.csv', content_type: 'text/csv')

    described_class.new.perform(data_import)

    expect(data_import.reload.status).to eq('failed')
  end

  it 'M4 — does NOT send contact_import_failed mailer when conversations CSV is malformed' do
    data_import = DataImport.create!(data_type: 'conversations')
    data_import.import_file.attach(io: StringIO.new("just,one\n"), filename: 'c.csv', content_type: 'text/csv')

    mailer_double = instance_double(ActionMailer::MessageDelivery, deliver_later: true)
    expect(AdministratorNotifications::AccountNotificationMailer).not_to receive(:with)

    described_class.new.perform(data_import)
    expect(data_import.reload.status).to eq('failed')
  end

  describe 'contacts import — batch label (import.label)' do
    let(:contacts_csv) do
      [
        'tipo,nome,email,telefone',
        'person,Joana Lima,joana.lima@example.com,+5511977776666',
        'person,Pedro Alves,pedro.alves@example.com,+5511988885555'
      ].join("\n")
    end

    it 'tags every contact in the batch when import.label is set' do
      data_import = DataImport.create!(data_type: 'contacts', label: 'suporte')
      data_import.import_file.attach(io: StringIO.new(contacts_csv), filename: 'contacts.csv', content_type: 'text/csv')

      described_class.new.perform(data_import)

      joana = Contact.find_by(email: 'joana.lima@example.com')
      pedro = Contact.find_by(email: 'pedro.alves@example.com')
      expect(joana.label_list).to include('suporte')
      expect(pedro.label_list).to include('suporte')
    end

    it 'leaves contacts untagged when no import.label is set (backward compatible)' do
      data_import = DataImport.create!(data_type: 'contacts')
      data_import.import_file.attach(io: StringIO.new(contacts_csv), filename: 'contacts.csv', content_type: 'text/csv')

      described_class.new.perform(data_import)

      joana = Contact.find_by(email: 'joana.lima@example.com')
      expect(joana.label_list).to be_empty
    end

    it 'adds the batch label to an existing contact matched by identity, without clobbering its current labels' do
      existing = Contact.create!(name: 'Joana Lima', email: 'joana.lima@example.com', label_list: 'vip')

      data_import = DataImport.create!(data_type: 'contacts', label: 'suporte')
      data_import.import_file.attach(io: StringIO.new(contacts_csv), filename: 'contacts.csv', content_type: 'text/csv')

      described_class.new.perform(data_import)

      expect(existing.reload.label_list).to contain_exactly('vip', 'suporte')
    end

    it 'publishes contact.label.added (evo-flow event) via the label_list= setter path' do
      data_import = DataImport.create!(data_type: 'contacts', label: 'suporte')
      data_import.import_file.attach(io: StringIO.new(contacts_csv), filename: 'contacts.csv', content_type: 'text/csv')

      events = []
      allow_any_instance_of(Contact).to receive(:publish_label_added) { |_, name| events << name }

      described_class.new.perform(data_import)

      expect(events).to eq(%w[suporte suporte])
    end
  end

  describe 'contacts import — semicolon-delimited CSV (Excel pt-BR export)' do
    it 'parses name/phone correctly instead of collapsing the row into one blank column' do
      csv = [
        'tipo;nome;primeiro_nome;sobrenome;email;telefone',
        ';Vanderlene do Nascimento Carlos;;;;5593991640367'
      ].join("\n")
      data_import = DataImport.create!(data_type: 'contacts')
      data_import.import_file.attach(io: StringIO.new(csv), filename: 'contacts.csv', content_type: 'text/csv')

      described_class.new.perform(data_import)

      # DDD 93 (AP) strips the nono digito per Whatsapp::PhoneNumberNormalizer's
      # BR rules (Contact#prepare_phone_number_attribute normalizes on save).
      contact = Contact.find_by(phone_number: '+559391640367')
      expect(contact).to be_present
      expect(contact.name).to eq('Vanderlene do Nascimento Carlos')
    end

    it 'matches an existing contact whose stored phone was already nono-digito-normalized, instead of duplicating it' do
      existing = Contact.create!(name: 'Vanderlene', phone_number: '+5593991640367')
      expect(existing.reload.phone_number).to eq('+559391640367')

      csv = [
        'tipo;nome;primeiro_nome;sobrenome;email;telefone',
        ';Vanderlene do Nascimento Carlos;;;;5593991640367'
      ].join("\n")
      data_import = DataImport.create!(data_type: 'contacts')
      data_import.import_file.attach(io: StringIO.new(csv), filename: 'contacts.csv', content_type: 'text/csv')

      described_class.new.perform(data_import)

      expect(Contact.where(phone_number: '+559391640367').count).to eq(1)
      expect(existing.reload.name).to eq('Vanderlene do Nascimento Carlos')
    end
  end
end
