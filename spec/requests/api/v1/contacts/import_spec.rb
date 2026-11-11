# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /api/v1/contacts/import', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }
  let(:csv_file) do
    fixture = Tempfile.new(['contacts', '.csv'])
    fixture.write("tipo,nome,email\nperson,Joana Lima,joana.lima@example.com\n")
    fixture.rewind
    Rack::Test::UploadedFile.new(fixture.path, 'text/csv')
  end

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }
  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  it 'stores the chosen label on the DataImport record for the background job to apply' do
    post '/api/v1/contacts/import',
         params: { import_file: csv_file, label: 'suporte' },
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(DataImport.last.label).to eq('suporte')
  end

  it 'leaves label nil when none is provided (backward compatible)' do
    post '/api/v1/contacts/import',
         params: { import_file: csv_file },
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(DataImport.last.label).to be_nil
  end
end
