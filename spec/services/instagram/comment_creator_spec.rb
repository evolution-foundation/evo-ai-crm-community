# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Instagram::CommentCreator do
  let(:ig_id) { "1784#{SecureRandom.random_number(10**10)}" }

  let(:channel) do
    ch = Channel::Instagram.new(instagram_id: ig_id, access_token: 'token')
    ch.save!(validate: false)
    ch
  end

  let!(:inbox) { Inbox.create!(channel: channel, name: "IG #{SecureRandom.hex(3)}") }

  def comment_value(id:, text: 'Qual o valor', from_id: '1134687895664215', extra: {})
    {
      'from' => { 'id' => from_id, 'username' => 'graca8918' },
      'media' => { 'id' => '18063450365360157', 'media_product_type' => 'FEED' },
      'id' => id,
      'text' => text
    }.merge(extra)
  end

  before { allow(MetaBaseUrl).to receive(:enabled?).and_return(true) } # skips the permalink lookup

  def perform(value)
    described_class.new(ig_account_id: ig_id, value: value).perform
  end

  it 'creates a comment conversation with the comment as an incoming message' do
    expect { perform(comment_value(id: 'c1')) }.to change(Conversation, :count).by(1).and change(Message, :count).by(1)

    conversation = Conversation.order(:created_at).last
    expect(conversation.additional_attributes['conversation_type']).to eq('instagram_comment')
    expect(conversation.contact.name).to eq('graca8918')

    message = conversation.messages.last
    expect(message).to be_incoming
    expect(message.content).to eq('Qual o valor')
    expect(message.source_id).to eq('c1')
    expect(message.content_attributes['instagram_comment']).to be(true)
  end

  it 'groups further comments of the same person in the same open conversation' do
    perform(comment_value(id: 'c1'))

    expect { perform(comment_value(id: 'c2', text: 'E o prazo?')) }
      .to change(Conversation, :count).by(0).and change(Message, :count).by(1)
  end

  it 'ignores a comment that was already processed' do
    perform(comment_value(id: 'c1'))

    expect { perform(comment_value(id: 'c1')) }.not_to change(Message, :count)
  end

  it 'ignores comments written by the connected account itself' do
    expect { perform(comment_value(id: 'c1', from_id: ig_id)) }.not_to change(Message, :count)
  end

  it 'ignores comments for an unknown instagram account' do
    expect do
      described_class.new(ig_account_id: 'unknown', value: comment_value(id: 'c1')).perform
    end.not_to change(Message, :count)
  end

  it 'keeps the parent comment id when the comment is a reply' do
    perform(comment_value(id: 'c2', extra: { 'parent_id' => 'c1' }))

    expect(Message.last.content_attributes['in_reply_to_external_id']).to eq('c1')
  end
end
