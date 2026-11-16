# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Account::ContactsExportJob do
  let(:user) { User.create!(name: 'Exportador', email: %w[exportador example.com].join('@')) }

  around do |example|
    original = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :test
    example.run
  ensure
    ActionMailer::Base.delivery_method = original
  end

  before do
    allow_any_instance_of(AdministratorNotifications::AccountNotificationMailer)
      .to receive(:smtp_config_set_or_development?).and_return(true)
    ActionMailer::Base.deliveries.clear
  end

  def export_rows(columns = %w[name email phone_number])
    described_class.perform_now(user.id, columns, {})
    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([user.email])
    csv = mail.attachments.find { |a| a.filename.end_with?('.csv') }
    expect(csv).to be_present
    CSV.parse(csv.decoded)
  end

  it 'emails the CSV with the contacts to whoever asked for the export' do
    Contact.create!(name: 'Ana Export', email: %w[ana-export example.com].join('@'))
    Contact.create!(name: 'Bruno Export', phone_number: '+5511999990000')

    rows = export_rows

    expect(rows.first).to eq(%w[name email phone_number])
    expect(rows).to include(['Ana Export', %w[ana-export example.com].join('@'), nil], ['Bruno Export', nil, '+5511999990000'])
  end

  it 'keeps a cell a spreadsheet would run as a formula as text' do
    Contact.create!(name: '=HYPERLINK("https://example.com","x")', phone_number: '+5511999990001')

    rows = export_rows(%w[name phone_number])

    expect(rows.last).to eq(["'=HYPERLINK(\"https://example.com\",\"x\")", '+5511999990001'])
  end

  context 'when the account masks contact PII' do
    before do
      allow(RuntimeConfig).to receive(:account).and_return({ 'settings' => { 'mask_contact_pii' => true } })
      Contact.create!(name: 'Carla Export', email: %w[carla-export example.com].join('@'), phone_number: '+5511988887777')
    end

    it 'masks email and phone for an agent' do
      allow(User).to receive(:find).with(user.id).and_return(user)
      allow(user).to receive(:administrator?).and_return(false)

      expect(export_rows.last).to eq(['Carla Export', %w[c*** example.com].join('@'), '+*********7777'])
    end

    it 'keeps the raw values for an administrator' do
      allow(User).to receive(:find).with(user.id).and_return(user)
      allow(user).to receive(:administrator?).and_return(true)

      expect(export_rows.last).to eq(['Carla Export', %w[carla-export example.com].join('@'), '+5511988887777'])
    end
  end
end
