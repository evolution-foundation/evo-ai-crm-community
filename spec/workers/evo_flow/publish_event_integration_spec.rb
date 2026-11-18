require 'rails_helper'
require 'webmock/rspec'

# F10/F5: exercises the real data path PayloadBuilder -> PublishEventWorker ->
# Client -> evo-flow wire, with nothing mocked but the HTTP boundary. Catches
# DTO-shape and symbol/string-key regressions the over-mocked unit specs miss.
RSpec.describe 'EvoFlow publish integration', type: :job do
  let(:message_id) { EvoFlow::PayloadBuilder.message_id_for('contact.created', 42, 'evt-uuid') }
  let(:payload) do
    EvoFlow::PayloadBuilder.build_track(
      event_name: 'contact.created', contact_id: 42, properties: { plan: 'pro' },
      occurred_at: Time.zone.parse('2026-05-19T12:00:00Z'), message_id: message_id
    )
  end

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch)
      .with('EVO_FLOW_API_URL', EvoFlow::Client::DEFAULT_API_URL)
      .and_return('http://evo-flow:3000/api/v1')
    allow(ENV).to receive(:fetch)
      .with('AUTH_APIKEY_INTEGRATION_LOCAL', nil).and_return('integration-key')
  end

  def real_track_dto?(request)
    body = JSON.parse(request.body)
    body['messageId'] == message_id && body['contactId'] == '42' &&
      body['event'] == 'contact.created' && body['properties'] == { 'plan' => 'pro' } &&
      body['timestamp'] == '2026-05-19T12:00:00.000Z' &&
      !body.key?('accountId') && !body.key?('eventType')
  end

  it 'sends the real built track DTO over the wire and logs the messageId' do
    stub = stub_request(:post, 'http://evo-flow:3000/api/v1/events/track')
           .with(headers: { 'X-Integration-API-Key' => 'integration-key',
                            'Content-Type' => 'application/json' }) { |req| real_track_dto?(req) }
           .to_return(status: 200, body: { messageId: message_id, status: 'queued' }.to_json,
                      headers: { 'Content-Type' => 'application/json' })
    expect(Rails.logger).to receive(:info).with(/messageId=#{message_id}/)

    EvoFlow::PublishEventWorker.new.perform('/events/track', payload)

    expect(stub).to have_been_requested
  end
end
