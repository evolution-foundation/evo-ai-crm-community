require 'rails_helper'

RSpec.describe Webhooks::WhatsappController, type: :controller do
  include ActiveJob::TestHelper
  let(:body) { { object: 'whatsapp_business_account', entry: [] }.to_json }
  before do
    ActiveJob::Base.queue_adapter = :test
    clear_enqueued_jobs
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('WP_APP_SECRET', '').and_return('synthetic-app-secret')
  end

  it 'rejects missing, invalid and forged signatures before enqueueing' do
    [nil, 'sha256=' + '0' * 64].each do |signature|
      request.headers['X-Hub-Signature-256'] = signature
      post :process_payload, body: body, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(enqueued_jobs).to be_empty
    end
  end

  it 'accepts only a signature for the exact raw body' do
    request.headers['X-Hub-Signature-256'] = 'sha256=' + OpenSSL::HMAC.hexdigest('SHA256', 'synthetic-app-secret', body)
    post :process_payload, body: body, as: :json
    expect(response).to have_http_status(:ok)
    expect(enqueued_jobs.map { |job| job[:job] }).to eq([Webhooks::WhatsappEventsJob])
  end

  it 'fails closed when no app secret is configured' do
    allow(GlobalConfigService).to receive(:load).with('WP_APP_SECRET', '').and_return('')
    allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', '').and_return('')
    post :process_payload, body: body, as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(enqueued_jobs).to be_empty
  end
end
