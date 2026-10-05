# frozen_string_literal: true

require 'rails_helper'

# Control / content-less inbound messages must never become an empty bubble.
# Runs the real service against the DB, one fixture per payload shape.
RSpec.describe 'WhatsApp evolution_go inbound control messages' do # rubocop:disable RSpec/DescribeClass
  let(:channel) do
    ch = Channel::Whatsapp.new(phone_number: "+55119#{rand(10_000_000..99_999_999)}", provider: 'evolution_go')
    ch.save!(validate: false)
    ch
  end
  let(:inbox) { Inbox.create!(name: 'WA Evolution Go', channel: channel) }

  # Same shape production gets: params.to_unsafe_hash through ActiveJob.
  def payload(name)
    JSON.parse(file_fixture("whatsapp/evolution_go/#{name}.json").read).with_indifferent_access
  end

  def run(params)
    Whatsapp::IncomingMessageEvolutionGoService.new(inbox: inbox, params: params).perform
  end

  def run_fixture(name)
    run(payload(name))
  end

  def empty_bubbles
    inbox.messages.where(content: ['', nil]).where.missing(:attachments)
  end

  %w[reaction reaction_remove context_only poll_creation poll_update unsupported edit].each do |name|
    it "creates no message and no conversation for #{name}" do
      expect { run_fixture(name) }.not_to change(Message, :count)
      expect(inbox.conversations.count).to eq(0)
    end
  end

  it 'does not reopen a resolved conversation on a reaction' do
    run_fixture('text')
    conversation = inbox.conversations.last
    conversation.update!(status: :resolved)

    expect { run_fixture('reaction') }.not_to change(Conversation, :count)
    expect(conversation.reload.status).to eq('resolved')
  end

  context 'with an echo from the phone, for a contact the echo path resolves' do
    def echo(name, id)
      params = payload(name)
      params[:data][:Info].merge!(IsFromMe: true, ID: id)
      params
    end

    before do
      run_fixture('text')
      inbox.contacts.last.update!(identifier: '5511900000001@s.whatsapp.net')
    end

    it 'records an echoed text (control: the echo path is reachable)' do
      expect { run(echo('text', 'ECHO-TEXT')) }.to change(Message, :count).by(1)
    end

    it 'ignores an echoed reaction' do
      expect { run(echo('reaction', 'ECHO-REACT')) }.not_to change(Message, :count)
    end
  end

  it 'keeps text as a message (control)' do
    expect { run_fixture('text') }.to change(Message, :count).by(1)
    expect(inbox.messages.last.content).to eq('Olá, tudo bem?')
  end

  it 'keeps media without caption as a message with its attachment' do
    expect { run_fixture('image_no_caption') }.to change(Message, :count).by(1)
    expect(inbox.messages.last.attachments.count).to eq(1)
  end

  # The Evolution Go server unwraps ephemeralMessage (UnwrapRaw); the CRM relies on that.
  it 'keeps a text flagged IsEphemeral' do
    run_fixture('ephemeral_text')

    expect(inbox.messages.last.content).to eq('mensagem temporária')
  end

  it 'renders location as text with its coordinates in content_attributes' do
    expect { run_fixture('location') }.to change(Message, :count).by(1)

    message = inbox.messages.last
    expect(message.content).to eq('Location: -23.5505, -46.6333')
    expect(message.content_attributes['location']).to include(
      'latitude' => -23.5505, 'longitude' => -46.6333, 'name' => 'Praça da Sé', 'address' => 'Sé, São Paulo - SP'
    )
  end

  it 'renders a contact card with its name and vcard' do
    run_fixture('contact')

    message = inbox.messages.last
    expect(message.content).to eq('Carol Souza')
    expect(message.content_attributes['contacts']).to contain_exactly(
      include('display_name' => 'Carol Souza', 'vcard' => a_string_including('FN:Carol Souza'))
    )
  end

  it 'renders a contacts array with one entry per contact' do
    run_fixture('contacts_array')

    message = inbox.messages.last
    expect(message.content).to eq('Carol Souza')
    expect(message.content_attributes['contacts'].pluck('display_name')).to eq(['Carol Souza', 'Dave Lima'])
  end

  context 'with the original message already stored' do
    let!(:original) do
      run_fixture('text')
      message = inbox.messages.last
      message.update!(source_id: '3EB0ORIGINAL0001')
      message
    end

    it 'marks the original revoked on a revoke, without creating a message' do
      expect { run_fixture('revoke') }.not_to change(Message, :count)
      expect(original.reload.revoked_by_contact).to be(true)
    end

    it 'marks the original revoked when the zero-valued type is omitted' do
      params = payload('revoke')
      params[:data][:Message][:protocolMessage].delete(:type)

      run(params)

      expect(original.reload.revoked_by_contact).to be(true)
    end

    it 'leaves the original untouched on an edit' do
      expect { run_fixture('edit') }.not_to change(Message, :count)

      original.reload
      expect(original.revoked_by_contact).to be_falsey
      expect(original.content).to eq('Olá, tudo bem?')
    end
  end

  it 'leaves no empty bubble after every payload shape' do
    Dir[Rails.root.join('spec/fixtures/files/whatsapp/evolution_go/*.json')].each do |path|
      run_fixture(File.basename(path, '.json'))
    end

    expect(empty_bubbles.count).to eq(0)
  end
end
