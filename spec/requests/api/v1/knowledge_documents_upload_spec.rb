require 'rails_helper'
require 'webmock/rspec'

# Auth pattern copied from spec/requests/api/v1/agents_spec.rb (see Task 1.5's
# ledger ruling — this codebase stubs an external evo-auth-service, no Devise
# sign_in). Permission key reused from the ai_agents.* catalog resource, same
# ruling as Task 1.5.
RSpec.describe 'Api::V1::KnowledgeDocuments upload', type: :request do
  include ActiveJob::TestHelper

  let(:base_url) { 'http://auth.test' }
  let(:validate_url) { "#{base_url}/api/v1/auth/validate" }
  let(:token) { 'test-bearer-token' }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let!(:user) { User.create!(name: 'Knowledge Upload Test User', email: "knowledge-upload-#{SecureRandom.hex(4)}@example.com") }
  let(:knowledge_base) { create(:knowledge_base) }

  around do |example|
    original_base_url = ENV['EVO_AUTH_SERVICE_URL']
    ENV['EVO_AUTH_SERVICE_URL'] = base_url
    Rails.cache.clear
    Current.reset
    example.run
    Rails.cache.clear
    Current.reset
    ENV['EVO_AUTH_SERVICE_URL'] = original_base_url
  end

  before do
    stub_request(:post, validate_url)
      .with(headers: { 'Authorization' => "Bearer #{token}" })
      .to_return(
        status: 200,
        body: { success: true, data: { user: { id: user.id, email: user.email, role: { id: 1, key: 'test_role', name: 'test_role' } } } }.to_json,
        headers: { 'Content-Type' => 'application/json' }
      )
    stub_request(:post, "#{base_url}/api/v1/users/#{user.id}/check_permission")
      .to_return do |request|
        permission_key = JSON.parse(request.body)['permission_key']
        {
          status: 200,
          body: { success: true, data: { has_permission: %w[ai_agents.read ai_agents.create ai_agents.delete].include?(permission_key) } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        }
      end
  end

  it 'accepts a PDF upload and creates a processing document' do
    file = fixture_file_upload(Rails.root.join('spec/fixtures/files/sample.pdf'), 'application/pdf')

    post "/api/v1/knowledge_bases/#{knowledge_base.id}/documents/upload",
         params: { file: file, title: 'Doc via upload' },
         headers: headers

    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)['data']['status']).to eq('processing')
  end

  it 'rejects a file over 50MB' do
    # A plain double stubbed with `size: 51.megabytes` never reaches the
    # controller with that size: Rack::Test only builds a multipart request
    # (and transmits real bytes) for an actual Rack::Test::UploadedFile — a
    # bare double lacks `set_encoding`/`to_path`, so Rack::Test would either
    # serialize it as an inert string param or send a zero-byte file part,
    # and the byte-size validation would never see 51MB. Wrapping a real
    # oversized StringIO in Rack::Test::UploadedFile makes the transmitted
    # bytes (and therefore ActiveStorage's blob.byte_size) genuinely exceed
    # the 50MB limit, so the validation is exercised for real.
    oversized_content = StringIO.new('x' * 51.megabytes)
    file = Rack::Test::UploadedFile.new(oversized_content, 'application/pdf', original_filename: 'big.pdf')

    post "/api/v1/knowledge_bases/#{knowledge_base.id}/documents/upload",
         params: { file: file, title: 'Too big' },
         headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors'].first).to include('50MB')
  end

  it 'enqueues ingestion after a successful upload' do
    file = fixture_file_upload(Rails.root.join('spec/fixtures/files/sample.pdf'), 'application/pdf')

    expect do
      post "/api/v1/knowledge_bases/#{knowledge_base.id}/documents/upload",
           params: { file: file, title: 'Doc via upload' },
           headers: headers
    end.to have_enqueued_job(Knowledge::IngestJob)
  end
end
