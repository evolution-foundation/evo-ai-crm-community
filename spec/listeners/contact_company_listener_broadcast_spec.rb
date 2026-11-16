# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ContactCompanyListener do
  include ActiveJob::TestHelper

  let(:person) { Contact.create!(name: 'Pessoa') }
  let(:company) { Contact.create!(name: 'Empresa', type: 'company') }

  before do
    User.create!(name: 'Agente', email: %w[agente-empresa example.com].join('@'))
    allow(RuntimeConfig).to receive(:account).and_return({ 'id' => 'conta', 'settings' => {} })
    clear_enqueued_jobs
  end

  it 'broadcasts a contact-company link once' do
    Rails.configuration.dispatcher.dispatch('contact_company_linked', Time.zone.now, contact: person, company: company)
    perform_enqueued_jobs(only: EventDispatcherJob)

    broadcasts = enqueued_jobs.select do |job|
      job['job_class'] == 'ActionCableBroadcastJob' && job['arguments'].second == 'CONTACT_COMPANY_LINKED'
    end
    expect(broadcasts.size).to eq(1)
  end
end
