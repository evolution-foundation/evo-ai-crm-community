# frozen_string_literal: true

require 'rails_helper'

# The send-response contract consumed by SendOnWhatsappService: a delivered
# send without an ID must not read as a failure.
RSpec.describe Whatsapp::Providers::EvolutionGoService do
  let(:whatsapp_channel) do
    instance_double(Channel::Whatsapp, provider_config: { 'api_key' => 'token', 'instance_name' => 'inst' })
  end
  let(:service) { described_class.new(whatsapp_channel: whatsapp_channel) }

  describe '#process_evolution_go_response' do
    it 'returns the message id when the API provides one' do
      response = instance_double(
        HTTParty::Response,
        success?: true, code: 200,
        parsed_response: { 'data' => { 'Info' => { 'ID' => 'GO123' } }, 'message' => 'success' },
        body: '{}'
      )

      expect(service.send(:process_evolution_go_response, response)).to eq('GO123')
    end

    it 'returns true (success without id) when HTTP 200 carries no ID' do
      response = instance_double(
        HTTParty::Response,
        success?: true, code: 200,
        parsed_response: { 'message' => 'success' },
        body: '{}'
      )

      expect(service.send(:process_evolution_go_response, response)).to be(true)
    end

    it 'raises on HTTP error (handled by SendReplyJob rescue)' do
      response = instance_double(
        HTTParty::Response,
        success?: false, code: 500,
        parsed_response: {},
        body: 'boom'
      )

      expect { service.send(:process_evolution_go_response, response) }
        .to raise_error(/HTTP 500/)
    end
  end

  describe '#send_message — unsupported content (CRM-448)' do
    it 'flags the message is_unsupported and returns nil (the caller turns it into failed)' do
      message = instance_double(Message, attachments: [], content_type: 'text', content: nil)
      expect(message).to receive(:update!).with(is_unsupported: true)

      expect(service.send_message('5511999999999', message)).to be_nil
    end
  end

  # A quoted reply carries the original author's JID. The contact stores the number as
  # informed, so the participant has to be derived, not read off the stored string.
  describe '#extract_participant_from_message' do
    def incoming_from(phone_number)
      instance_double(
        Message, message_type: 'incoming', id: 1,
                 sender: instance_double(Contact, phone_number: phone_number)
      )
    end

    it 'drops the ninth digit of a DDD >= 31 mobile stored as informed' do
      participant = service.send(:extract_participant_from_message, incoming_from('+5531988887777'))

      expect(participant).to eq('553188887777@s.whatsapp.net')
    end

    it 'keeps the ninth digit where WhatsApp keeps it (DDD < 31)' do
      participant = service.send(:extract_participant_from_message, incoming_from('+5511988887777'))

      expect(participant).to eq('5511988887777@s.whatsapp.net')
    end

    it 'leaves a number already in the channel form unchanged' do
      participant = service.send(:extract_participant_from_message, incoming_from('+553188887777'))

      expect(participant).to eq('553188887777@s.whatsapp.net')
    end

    it 'is nil without a phone on the sender' do
      expect(service.send(:extract_participant_from_message, incoming_from(nil))).to be_nil
    end
  end
end
