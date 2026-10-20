require 'rails_helper'
require 'webmock/rspec'
WebMock.disable_net_connect!(allow_localhost: true)

RSpec.describe 'Meta standby observation' do
  include ActiveJob::TestHelper

  def envelope(body, phone: 'PHONE_TEST', field: 'standby')
    { object: 'whatsapp_business_account', entry: [{ id: 'WABA_TEST', changes: [{ field: field,
      value: { metadata: { phone_number_id: phone, display_phone_number: '15550000001' },
               **(field == 'standby' ? { standby: body } : body) } }] }] }.with_indifferent_access
  end

  def echo(id = 'wamid.synthetic.out')
    { id: id, timestamp: '1780000000', message: { to: '5511987654321', type: 'text', text: { body: 'Synthetic echo' } } }
  end

  def make_inbox(phone_id, phone)
    channel = Channel::Whatsapp.new(provider: 'whatsapp_cloud', phone_number: phone,
      provider_config: { phone_number_id: phone_id, waba_id: 'WABA_TEST', api_key: 'synthetic' })
    allow(channel).to receive(:validate_provider_config)
    allow(channel).to receive(:subscribe)
    channel.save!(validate: false)
    Inbox.create!(name: 'Synthetic inbox', channel: channel)
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow_any_instance_of(Channel::Whatsapp).to receive(:subscribe)
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates)
    allow(ActionCableListener.instance).to receive(:message_created)
    allow(ActionCableListener.instance).to receive(:message_updated)
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
  end

  it 'splits mixed arrays, changes, entries, ignores invalid items and preserves direction' do
    data = envelope({ messages: [{ id: 'in', from: '5511987654321', type: 'text', timestamp: '1780000000' }],
      message_echoes: [nil, echo], statuses: [{ id: 'out', status: 'read' }] })
    data[:entry] << envelope({ message_echoes: [echo('second')] }, phone: 'SECOND')[:entry].first
    result = Whatsapp::CloudEventNormalizer.call(data)
    expect(result.size).to eq(4)
    expect(result.last.dig(:entry, 0, :changes, 0, :value, :metadata, :phone_number_id)).to eq('SECOND')
    expect(result[1].dig(:entry, 0, :changes, 0, :value, :message_echoes, 0, :text, :body)).to eq('Synthetic echo')
  end

  it 'persists an echo without from/contact, preserves timestamp, and cannot send or trigger automation' do
    inbox = make_inbox('PHONE_TEST', '+15550000001')
    expect(Whatsapp::SendOnWhatsappService).not_to receive(:new)
    expect_any_instance_of(Message).not_to receive(:execute_after_create_commit_callbacks)
    expect_any_instance_of(Message).not_to receive(:publish_message_created)
    job = Webhooks::WhatsappEventsJob.new
    data = envelope({ message_echoes: [echo] })
    2.times { job.perform(data) }
    msg = inbox.messages.find_by!(source_id: 'wamid.synthetic.out')
    expect(msg).to be_outgoing
    expect(msg.content).to eq('Synthetic echo')
    expect(msg.created_at.to_i).to eq(1780000000)
    expect(msg).to be_whatsapp_observed
    expect(inbox.messages.where(source_id: msg.source_id).count).to eq(1)
    SendReplyJob.perform_now(msg.id)
    flat = echo[:message].merge(id: echo[:id], timestamp: echo[:timestamp])
    job.perform(envelope({ message_echoes: [flat] }, field: 'smb_message_echoes'))
    expect(inbox.messages.count).to eq(1)
  end

  it 'correlates earlier read and refuses later delivered, without empty bubbles' do
    inbox = make_inbox('PHONE_TEST', '+15550000001')
    job = Webhooks::WhatsappEventsJob.new
    job.perform(envelope({ statuses: [{ id: echo[:id], status: 'read' }] }))
    expect(inbox.messages.count).to eq(0)
    job.perform(envelope({ message_echoes: [echo] }))
    job.perform(envelope({ statuses: [{ id: echo[:id], status: 'delivered' }] }))
    expect(inbox.messages.first).to be_read
  end

  it 'isolates equal external IDs in two inboxes and handles contactless inbound alongside echoes' do
    first = make_inbox('PHONE_TEST', '+15550000001')
    second = make_inbox('SECOND', '+15550000003')
    inbound = { id: 'incoming', from: '5511987654321', type: 'text', timestamp: '1780000000', text: { body: 'Incoming' } }
    data = envelope({ messages: [inbound], message_echoes: [echo] })
    data[:entry] << envelope({ messages: [inbound], message_echoes: [echo] }, phone: 'SECOND')[:entry].first
    Webhooks::WhatsappEventsJob.new.perform(data)
    expect(first.messages.where(source_id: ['incoming', echo[:id]]).count).to eq(2)
    expect(second.messages.where(source_id: ['incoming', echo[:id]]).count).to eq(2)
    expect(first.messages.find_by!(source_id: 'incoming')).to be_incoming
    expect(first.contact_inboxes.count).to eq(1)
  end

  it 'renders template parameters with a definition and gives an explicit fallback without one' do
    message = { type: 'template', template: { name: 'hello', components: [{ type: 'body', parameters: [{ text: 'Ana' }] }] },
      standby_template: { components: [{ type: 'BODY', text: 'Olá {{1}}' }] } }.with_indifferent_access
    expect(Whatsapp::ObservedContent.render(message)).to eq('Olá Ana')
    message.delete(:standby_template)
    expect(Whatsapp::ObservedContent.render(message)).to include('conteúdo completo indisponível')
  end

  it 'keeps history envelopes unchanged' do
    data = envelope({ history: [] }, field: 'history')
    expect(Whatsapp::CloudEventNormalizer.call(data)).to eq([data])
  end
  it 'downloads an observed media ID with the channel credentials and persists its attachment' do
    inbox = make_inbox('PHONE_TEST', '+15550000001')
    media = echo('media')
    media[:message] = { to: '5511987654321', type: 'image', image: { id: 'media-id', caption: 'Synthetic image' } }
    file = Tempfile.new(['standby', '.png'])
    file.binmode
    file.write(Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jR1cAAAAASUVORK5CYII='))
    file.rewind
    metadata_request = stub_request(:get, inbox.channel.media_url('media-id'))
      .with(headers: inbox.channel.api_headers)
      .to_return(status: 200, body: { url: 'https://media.example/synthetic.png' }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
    download_request = stub_request(:get, 'https://media.example/synthetic.png')
      .with(headers: inbox.channel.api_headers)
      .to_return(status: 200, body: file.read, headers: { 'Content-Type' => 'image/png' })
    Webhooks::WhatsappEventsJob.new.perform(envelope({ message_echoes: [media] }))
    msg = inbox.messages.find_by!(source_id: 'media')
    expect(msg.content).to eq('Synthetic image')
    expect(msg.attachments.count).to eq(1)
    expect(msg.attachments.first.file).to be_attached
    expect(metadata_request).to have_been_requested.once
    expect(download_request).to have_been_requested.once
    expect(WebMock).not_to have_requested(:post, /graph.facebook.com/)
  ensure
    file&.close!
  end

  it 'mirrors only allowed changes, retries a failed destination and does not roll back CRM processing' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('WHATSAPP_MIRROR_ENABLED').and_return('true')
    allowed = envelope({ message_echoes: [echo] }, phone: Webhooks::WhatsappMirrorJob::PHONES.first)
    allowed[:entry].first[:id] = Webhooks::WhatsappMirrorJob::WABA
    allowed[:entry].first[:changes] << envelope({}, phone: 'FORBIDDEN')[:entry].first[:changes].first
    allowed[:entry] << envelope({ message_echoes: [echo('other')] })[:entry].first
    clear_enqueued_jobs
    Webhooks::WhatsappMirrorJob.enqueue_allowed(allowed)
    expect(enqueued_jobs.count).to eq(1)
    payload = ActiveJob::Arguments.deserialize(enqueued_jobs.first[:args]).first.with_indifferent_access
    expect(payload['entry'].size).to eq(1)
    expect(payload['entry'].first['changes'].size).to eq(1)
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with('WHATSAPP_MIRROR_URL').and_return('https://mirror.example/webhook/meta/mirror')
    allow(ENV).to receive(:fetch).with('WHATSAPP_MIRROR_TOKEN').and_return('synthetic-token-32-characters-long')
    stub_request(:post, 'https://mirror.example/webhook/meta/mirror').to_return(status: 503)
    clear_enqueued_jobs
    Webhooks::WhatsappMirrorJob.perform_now(payload, Time.current.to_i)
    expect(enqueued_jobs.map { |job| job[:job] }).to eq([Webhooks::WhatsappMirrorJob])
    expect(enqueued_jobs.first[:at]).to be > Time.current.to_f
    stub_request(:post, 'https://mirror.example/webhook/meta/mirror').to_return(status: 200, body: '{"status":"persisted"}')
    perform_enqueued_jobs
    expect(WebMock).to have_requested(:post, 'https://mirror.example/webhook/meta/mirror').twice
  end


  it 'retains early failure diagnostics and status identity without publishing automation' do
    inbox = make_inbox('PHONE_TEST', '+15550000001')
    job = Webhooks::WhatsappEventsJob.new
    status = { id: echo[:id], status: 'failed', recipient_id: '5511987654321', recipient_user_id: 'US.synthetic',
               errors: [{ code: 131000, title: 'Synthetic failure' }] }
    contact = { wa_id: '5511987654321', user_id: 'US.synthetic', profile: { username: 'synthetic' } }
    job.perform(envelope({ statuses: [status], contacts: [contact] }))
    expect_any_instance_of(Messages::StatusUpdateService).not_to receive(:perform)
    job.perform(envelope({ message_echoes: [echo] }))
    message = inbox.messages.first
    expect(message).to be_failed
    expect(message.content_attributes['external_error']).to eq('131000: Synthetic failure')
    expect(message.conversation.contact_inbox.bsuid).to eq('US.synthetic')
    expect(message.conversation.contact_inbox.whatsapp_username).to eq('synthetic')
  end

  it 'keeps a pending read terminal even when failure arrives before its echo' do
    inbox = make_inbox('PHONE_TEST', '+15550000001')
    job = Webhooks::WhatsappEventsJob.new
    %w[read failed delivered].each { |status| job.perform(envelope({ statuses: [{ id: echo[:id], status: status }] })) }
    job.perform(envelope({ message_echoes: [echo] }))
    expect(inbox.messages.first).to be_read
  end

  it 'commits CRM messages even if mirror enqueue fails and retries without duplication' do
    inbox = make_inbox('PHONE_TEST', '+15550000001')
    allow(Webhooks::WhatsappMirrorJob).to receive(:enqueue_allowed).and_raise('Queue unavailable')
    data = envelope({ message_echoes: [echo] })
    expect { Webhooks::WhatsappEventsJob.new.perform(data) }.to raise_error('Queue unavailable')
    expect(inbox.messages.count).to eq(1)
    allow(Webhooks::WhatsappMirrorJob).to receive(:enqueue_allowed).and_return(true)
    Webhooks::WhatsappEventsJob.new.perform(data)
    expect(inbox.messages.count).to eq(1)
  end

  it 'keeps link media as metadata and excludes raw observation data from all egress audiences' do
    inbox = make_inbox('PHONE_TEST', '+15550000001')
    media = echo('link')
    media[:message] = { to: '5511987654321', type: 'image', image: { link: 'https://untrusted.example/image.png' } }
    expect(AgentBots::RemoteMediaAttacher).not_to receive(:build_attachments)
    Webhooks::WhatsappEventsJob.new.perform(envelope({ message_echoes: [media] }))
    message = inbox.messages.first
    expect(message.content_attributes['observed_payload']).to be_present
    %i[broadcast per_request].each do |audience|
      expect(message.content_attributes_for_egress(audience: audience)).not_to have_key('observed_payload')
    end
    expect(message.push_event_data[:content_attributes]).not_to have_key('observed_payload')
    expect(message.attachments).to be_empty
  end

  it 'reuses a resolved locked conversation for observed inbound messages without reopening it' do
    inbox = make_inbox('PHONE_TEST', '+15550000001')
    inbox.update!(lock_to_single_conversation: true)
    job = Webhooks::WhatsappEventsJob.new
    job.perform(envelope({ message_echoes: [echo] }))
    conversation = inbox.messages.first.conversation
    conversation.update!(status: :resolved)
    inbound = { id: 'incoming-locked', from: '5511987654321', type: 'text', timestamp: '1780000000', text: { body: 'Incoming' } }
    job.perform(envelope({ messages: [inbound] }))
    expect(inbox.messages.find_by!(source_id: 'incoming-locked').conversation_id).to eq(conversation.id)
    expect(conversation.reload).to be_resolved
  end
end
