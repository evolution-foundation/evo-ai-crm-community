# frozen_string_literal: true

# Specs for Whatsapp::EvolutionHandlers::ContentHandlers#handle_contacts.
#
# Regression coverage for the "shared contact renders as raw text" bug: the
# Evolution API handler used to only stash the parsed vCard in
# content_attributes[:contacts] (never read by the frontend) instead of
# building a real Attachment, unlike Whatsapp::IncomingMessageBaseService and
# Whatsapp::IncomingMessageZapiService, which already create one Attachment
# (file_type: :contact) per phone number.

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Whatsapp::EvolutionHandlers::ContentHandlers' do
    it 'has spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Whatsapp::EvolutionHandlers::ContentHandlers do
  let(:host_class) do
    Class.new do
      include Whatsapp::EvolutionHandlers::ContentHandlers

      # Stub for the helper normally provided by Whatsapp::EvolutionHandlers::Helpers.
      attr_accessor :file_content_type

      def initialize(message:, raw_message:)
        @message = message
        @raw_message = raw_message
        @file_content_type = :contact
      end
    end
  end

  let(:message) { instance_double(Message, content_attributes: {}, attachments: attachments_relation) }
  let(:attachments_relation) { instance_double('AttachmentsRelation') }

  subject(:host) { host_class.new(message: message, raw_message: raw_message) }

  before do
    allow(attachments_relation).to receive(:build)
  end

  describe '#handle_contacts' do
    context 'with a single contactMessage carrying a vCard phone' do
      let(:raw_message) do
        {
          message: {
            contactMessage: {
              displayName: 'Fernanda Martins',
              vcard: "BEGIN:VCARD\nVERSION:3.0\nFN:Fernanda Martins\n" \
                     "TEL;type=CELL;waid=5511999998888:+55 11 99999-8888\nEND:VCARD"
            }
          }
        }
      end

      it 'creates one contact attachment with the phone and display name' do
        expect(attachments_relation).to receive(:build).with(
          file_type: 'contact',
          fallback_title: '+55 11 99999-8888',
          meta: { display_name: 'Fernanda Martins' }
        )

        host.handle_contacts
      end

      it 'keeps the raw vcard in content_attributes for reference' do
        host.handle_contacts

        expect(message.content_attributes[:contacts]).to eq(
          [{ display_name: 'Fernanda Martins', vcard: raw_message[:message][:contactMessage][:vcard] }]
        )
      end
    end

    context 'when displayName is absent but the vCard has an FN field' do
      let(:raw_message) do
        {
          message: {
            contactMessage: {
              displayName: nil,
              vcard: "BEGIN:VCARD\nFN:Carlos Souza\nTEL:+5511888887777\nEND:VCARD"
            }
          }
        }
      end

      it 'falls back to the vCard FN field for display_name' do
        expect(attachments_relation).to receive(:build).with(
          file_type: 'contact',
          fallback_title: '+5511888887777',
          meta: { display_name: 'Carlos Souza' }
        )

        host.handle_contacts
      end
    end

    context 'when the vCard has no TEL line' do
      let(:raw_message) do
        {
          message: {
            contactMessage: {
              displayName: 'No Phone Contact',
              vcard: "BEGIN:VCARD\nFN:No Phone Contact\nEND:VCARD"
            }
          }
        }
      end

      it 'falls back to the "Phone number is not available" placeholder' do
        expect(attachments_relation).to receive(:build).with(
          file_type: 'contact',
          fallback_title: 'Phone number is not available',
          meta: { display_name: 'No Phone Contact' }
        )

        host.handle_contacts
      end
    end

    context 'with a contactsArrayMessage carrying multiple contacts' do
      let(:raw_message) do
        {
          message: {
            contactsArrayMessage: {
              contacts: [
                { displayName: 'Contact A', vcard: 'TEL:+5511111111111' },
                { displayName: 'Contact B', vcard: 'TEL:+5511222222222' }
              ]
            }
          }
        }
      end

      it 'creates one attachment per contact' do
        expect(attachments_relation).to receive(:build).with(
          hash_including(fallback_title: '+5511111111111', meta: { display_name: 'Contact A' })
        )
        expect(attachments_relation).to receive(:build).with(
          hash_including(fallback_title: '+5511222222222', meta: { display_name: 'Contact B' })
        )

        host.handle_contacts
      end
    end

    context 'with a vCard exposing multiple TEL lines for the same contact' do
      let(:raw_message) do
        {
          message: {
            contactMessage: {
              displayName: 'Multi Phone',
              vcard: "BEGIN:VCARD\nFN:Multi Phone\nTEL;type=CELL:+5511333333333\n" \
                     "TEL;type=HOME:+5511444444444\nEND:VCARD"
            }
          }
        }
      end

      it 'creates one attachment per phone number found in the vCard' do
        expect(attachments_relation).to receive(:build).with(hash_including(fallback_title: '+5511333333333'))
        expect(attachments_relation).to receive(:build).with(hash_including(fallback_title: '+5511444444444'))

        host.handle_contacts
      end
    end

    context 'when there is neither contactMessage nor contactsArrayMessage' do
      let(:raw_message) { { message: {} } }

      it 'does not attempt to build any attachment' do
        expect(attachments_relation).not_to receive(:build)

        host.handle_contacts
      end
    end
  end
end
