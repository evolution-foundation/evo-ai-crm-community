# frozen_string_literal: true

require 'rails_helper'

# CRM-22: control / content-less inbound messages must never become an empty bubble.
# Runs the real service against the DB, one fixture per payload shape.
RSpec.describe 'WhatsApp evolution inbound control messages (CRM-22)' do # rubocop:disable RSpec/DescribeClass
  let(:channel) do
    ch = Channel::Whatsapp.new(phone_number: "+55119#{rand(10_000_000..99_999_999)}", provider: 'evolution')
    ch.save!(validate: false)
    ch
  end
  let(:inbox) { Inbox.create!(name: 'WA Evolution', channel: channel) }

  # Same shape production gets: params.to_unsafe_hash through ActiveJob.
  def payload(name)
    JSON.parse(file_fixture("whatsapp/evolution/#{name}.json").read).with_indifferent_access
  end

  def run_fixture(name)
    Whatsapp::IncomingMessageEvolutionService.new(inbox: inbox, params: payload(name)).perform
  end

  %w[reaction reaction_remove context_only poll_creation].each do |name|
    it "creates no message for #{name}" do
      expect { run_fixture(name) }.not_to change(Message, :count)
    end
  end

  it 'keeps text as a message (control)' do
    expect { run_fixture('text') }.to change(Message, :count).by(1)
    expect(inbox.messages.last.content).to eq('Olá, tudo bem?')
  end

  it 'keeps the text of a disappearing-chat message wrapped in ephemeralMessage' do
    expect { run_fixture('ephemeral_text') }.to change(Message, :count).by(1)
    expect(inbox.messages.last.content).to eq('mensagem temporária')
  end

  it 'keeps the media source sitting next to ephemeralMessage when unwrapping' do
    service = Whatsapp::IncomingMessageEvolutionService.new(inbox: inbox, params: {})
    data = { message: { ephemeralMessage: { message: { imageMessage: { mimetype: 'image/jpeg' } } },
                        base64: 'aW1n', mediaUrl: 'https://media.example.com/x.jpg' } }.with_indifferent_access

    message = service.send(:unwrap_ephemeral, data)[:message]

    expect(message.keys).to contain_exactly('imageMessage', 'base64', 'mediaUrl')
  end

  it 'keeps location with its coordinates' do
    run_fixture('location')

    message = inbox.messages.last
    expect(message.content).to eq('Location: -23.5505, -46.6333')
    expect(message.content_attributes['location']).to include('latitude' => -23.5505, 'longitude' => -46.6333)
  end

  it 'keeps a contact card' do
    run_fixture('contact')

    message = inbox.messages.last
    expect(message.content).to eq('Carol Souza')
    expect(message.content_attributes['contacts'].pluck('display_name')).to eq(['Carol Souza'])
  end

  context 'with the original message already stored' do
    let!(:original) do
      run_fixture('text')
      message = inbox.messages.last
      message.update!(source_id: '3EB0ORIGINAL0001')
      message
    end

    it 'marks the original revoked when the zero-valued type is omitted' do
      expect { run_fixture('revoke') }.not_to change(Message, :count)
      expect(original.reload.revoked_by_contact).to be(true)
    end

    it 'leaves the original untouched on an edit wrapped in a disappearing chat' do
      expect { run_fixture('edit_ephemeral') }.not_to change(Message, :count)
      expect(original.reload.revoked_by_contact).to be_falsey
    end
  end

  it 'leaves no empty bubble after every payload shape' do
    Dir[Rails.root.join('spec/fixtures/files/whatsapp/evolution/*.json')].each do |path|
      run_fixture(File.basename(path, '.json'))
    end

    expect(inbox.messages.where(content: ['', nil]).where.missing(:attachments).count).to eq(0)
  end
end
