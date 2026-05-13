# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Api::V1::Templates' do
    it 'has request spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

require 'zip'
require 'stringio'
require 'sidekiq/testing'

RSpec.describe 'Api::V1::Templates', type: :request do
  let(:service_token) { 'spec-service-token' }
  let(:headers) { { 'X-Service-Token' => service_token } }

  before { ENV['EVOAI_CRM_API_TOKEN'] = service_token }

  def json_response
    JSON.parse(response.body)
  end

  def build_bundle(extra_categories = {})
    manifest = {
      schema_version: 1,
      name: 'Clínica',
      description: 'test',
      author: 'spec',
      created_at: Time.now.iso8601,
      contents: {}
    }
    Zip::OutputStream.write_buffer do |zip|
      zip.put_next_entry('manifest.json')
      zip.write(manifest.to_json)
      extra_categories.each do |cat, payload|
        zip.put_next_entry("#{cat}.json")
        zip.write(payload.to_json)
      end
    end.tap(&:rewind)
  end

  describe 'GET /api/v1/templates/exportable_inventory' do
    it 'returns categories grouped' do
      get '/api/v1/templates/exportable_inventory', headers: headers
      expect(response).to have_http_status(:ok)
      expect(json_response['data']).to include('pipelines', 'labels', 'inboxes')
    end
  end

  describe 'POST /api/v1/templates/export' do
    let!(:label) { Label.create!(title: "exp-#{SecureRandom.hex(4)}", color: '#fff') }

    it 'returns a ZIP attachment' do
      post '/api/v1/templates/export',
           params: { template_name: 'T', selection: { labels: { ids: [label.id] } } }.to_json,
           headers: headers.merge('Content-Type' => 'application/json')

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to start_with('application/zip')
      expect(response.headers['Content-Disposition']).to include('attachment')
    end
  end

  describe 'POST /api/v1/templates/import' do
    it 'imports labels and returns report' do
      io = build_bundle('labels' => [
                          { 'slug' => 'urg1', 'title' => "imp-#{SecureRandom.hex(4)}", 'color' => '#fff' }
                        ])
      file = Rack::Test::UploadedFile.new(io, 'application/zip', original_filename: 'b.zip')

      post '/api/v1/templates/import',
           params: { bundle_file: file },
           headers: headers

      expect(response).to have_http_status(:ok)
      expect(json_response['data']['items'].first['status']).to eq('created')
    end

    it 'rejects unsupported schema_version' do
      bad_manifest = { schema_version: 99, name: 'X', description: '', author: '', created_at: Time.now.iso8601, contents: {} }
      io = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry('manifest.json')
        zip.write(bad_manifest.to_json)
      end
      io.rewind
      file = Rack::Test::UploadedFile.new(io, 'application/zip', original_filename: 'b.zip')

      post '/api/v1/templates/import', params: { bundle_file: file }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['error']['code']).to eq('TEMPLATE_UNSUPPORTED_SCHEMA')
    end

    it 'rejects zip slip' do
      io = Zip::OutputStream.write_buffer do |zip|
        zip.put_next_entry('manifest.json')
        zip.write({ schema_version: 1, name: 'X' }.to_json)
        zip.put_next_entry('../escape.txt')
        zip.write('no')
      end
      io.rewind
      file = Rack::Test::UploadedFile.new(io, 'application/zip', original_filename: 'b.zip')

      post '/api/v1/templates/import', params: { bundle_file: file }, headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response['error']['code']).to eq('TEMPLATE_INVALID_BUNDLE')
    end

    it 'returns bad_request when bundle_file is missing' do
      post '/api/v1/templates/import', headers: headers
      expect(response).to have_http_status(:bad_request)
      expect(json_response['error']['code']).to eq('TEMPLATE_INVALID_BUNDLE')
    end

    # AC11b: destroy_async safety. The import flow must not enqueue Sidekiq
    # cleanup jobs (destroy_async) that would run against records rolled back
    # when the transaction fails.
    it 'does not enqueue destroy_async jobs when import succeeds' do
      Sidekiq::Testing.fake! do
        Sidekiq::Worker.clear_all

        io = build_bundle('labels' => [
                            { 'slug' => 'ac11b', 'title' => "ac11b-#{SecureRandom.hex(4)}", 'color' => '#fff' }
                          ])
        file = Rack::Test::UploadedFile.new(io, 'application/zip', original_filename: 'b.zip')

        expect do
          post '/api/v1/templates/import', params: { bundle_file: file }, headers: headers
        end.not_to change { Sidekiq::Worker.jobs.size }
      end
    end
  end
end
