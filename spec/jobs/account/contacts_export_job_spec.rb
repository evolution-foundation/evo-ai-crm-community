# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe Account::ContactsExportJob do
  include ActiveJob::TestHelper

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

  it 'emails the CSV with the contacts to whoever asked for the export' do
    Contact.create!(name: 'Ana Export', email: %w[ana-export example.com].join('@'))
    Contact.create!(name: 'Bruno Export', phone_number: '+5511999990000')

    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      described_class.perform_now(user.id, %w[name email phone_number], {})
    end

    mail = ActionMailer::Base.deliveries.last
    expect(mail.to).to eq([user.email])
    csv = mail.attachments.find { |a| a.filename.end_with?('.csv') }
    expect(csv).to be_present
    rows = CSV.parse(csv.decoded)
    expect(rows.first).to eq(%w[name email phone_number])
    expect(rows.map(&:first)).to include('Ana Export', 'Bruno Export')
  end
end
