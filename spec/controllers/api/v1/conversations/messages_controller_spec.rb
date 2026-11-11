# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe Api::V1::Conversations::MessagesController do
    it 'has controller spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Api::V1::Conversations::MessagesController, type: :controller do
  let(:conversation) { instance_double(Conversation) }
  let(:message_record) { instance_double(Message, id: 7, status: current_status, reload: nil) }
  let(:current_status) { 'read' }

  before do
    controller.instance_variable_set(:@conversation, conversation)
    allow(conversation).to receive_message_chain(:messages, :find).and_return(message_record)
    allow(message_record).to receive(:reload).and_return(message_record)
  end

  # AC7: #update must respond 422 when the funnel rejects the
  # transition (e.g. read → delivered). Previously this path silently lied
  # with a 200 response despite no DB change.
  describe '#update — funnel rejection surfaces as 422' do
    before do
      allow(controller).to receive(:permitted_params).and_return(
        ActionController::Parameters.new(id: 7, status: 'delivered').permit(:id, :status, :external_error)
      )
    end

    it 'AC7: returns 422 with the from→to transition in details when the service rejects' do
      rejecting = instance_double(Messages::StatusUpdateService, perform: false)
      allow(Messages::StatusUpdateService).to receive(:new).and_return(rejecting)

      expect(controller).to receive(:error_response).with(
        ApiErrorCodes::VALIDATION_ERROR,
        'Invalid status transition',
        details: 'read → delivered',
        status: :unprocessable_entity
      )

      controller.send(:update)
    end

    context 'when the service accepts the transition (happy path)' do
      let(:current_status) { 'sent' }

      it 'AC7 happy path: serializes the message and responds success' do
        accepting = instance_double(Messages::StatusUpdateService, perform: true)
        allow(Messages::StatusUpdateService).to receive(:new).and_return(accepting)
        allow(MessageSerializer).to receive(:serialize).and_return({})

        expect(controller).to receive(:success_response)
        controller.send(:update)
      end
    end
  end

  # AC8: #retry must NOT publish a redundant sent → sent Wisper
  # event. Previously the controller called StatusUpdateService.perform on
  # the freshly reset record (status now 'sent'), which produced a no-op
  # Wisper publish that the EvoFlow listener could not map.
  describe '#retry — no redundant Wisper publish' do
    before do
      allow(controller).to receive(:permitted_params).and_return(
        ActionController::Parameters.new(id: 7).permit(:id)
      )
      allow(message_record).to receive(:update!)
      allow(SendReplyJob).to receive(:perform_now)
      allow(MessageSerializer).to receive(:serialize).and_return({})
      allow(controller).to receive(:success_response)
    end

    it 'AC8: resets to :sent and enqueues SendReplyJob WITHOUT invoking StatusUpdateService' do
      expect(message_record).to receive(:update!).with(status: :sent, content_attributes: {})
      expect(SendReplyJob).to receive(:perform_now).with(7)
      expect(Messages::StatusUpdateService).not_to receive(:new)

      controller.send(:retry)
    end
  end

  # Lets a reply preview resolve a message outside its currently loaded page
  # (e.g. "quoted message" pointing far back in a long conversation) with a
  # direct lookup instead of paging through the whole history to find it.
  describe '#resolve' do
    let(:uuid) { '550e8400-e29b-41d4-a716-446655440000' }
    let(:messages_relation) { instance_double(ActiveRecord::Relation) }

    before do
      allow(conversation).to receive(:messages).and_return(messages_relation)
    end

    context 'given our internal UUID' do
      before do
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(ref: uuid))
      end

      it 'looks it up by id and serializes the message' do
        allow(messages_relation).to receive(:find_by).with(id: uuid).and_return(message_record)
        allow(MessageSerializer).to receive(:serialize).with(
          message_record, include_attachments: true, include_sender: true
        ).and_return({ id: 7 })

        expect(controller).to receive(:success_response).with(
          data: { id: 7 },
          message: 'Message retrieved successfully'
        )

        controller.send(:resolve)
      end

      it 'returns 404 when no message with that id exists in this conversation' do
        allow(messages_relation).to receive(:find_by).with(id: uuid).and_return(nil)

        expect(controller).to receive(:error_response).with(
          ApiErrorCodes::RESOURCE_NOT_FOUND,
          'Message not found',
          status: :not_found
        )

        controller.send(:resolve)
      end
    end

    # An inbound WhatsApp reply quotes the OTHER party's WhatsApp message id
    # (content_attributes.in_reply_to_external_id) - never our internal id -
    # so ?ref= must also resolve against source_id, or these replies can
    # never be resolved/jumped to at all (the bug this endpoint exists to
    # fix). ?ref= (not a :id path segment) because these ids are base64-ish
    # and can contain "/", which breaks as a path segment even when
    # percent-encoded.
    context 'given a WhatsApp source_id (not a UUID)' do
      let(:source_id) { 'wamid.HBgLNTU5MTIzNDU2Nzg5FQIAERgSQUJDRA==' }

      before do
        allow(controller).to receive(:params).and_return(ActionController::Parameters.new(ref: source_id))
      end

      it 'looks it up by source_id instead of id (never queries the uuid column with it)' do
        expect(messages_relation).not_to receive(:find_by).with(id: source_id)
        allow(messages_relation).to receive(:find_by).with(source_id: source_id).and_return(message_record)
        allow(MessageSerializer).to receive(:serialize).and_return({ id: 7 })

        expect(controller).to receive(:success_response)

        controller.send(:resolve)
      end

      it 'returns 404 when no message with that source_id exists in this conversation' do
        allow(messages_relation).to receive(:find_by).with(source_id: source_id).and_return(nil)

        expect(controller).to receive(:error_response).with(
          ApiErrorCodes::RESOURCE_NOT_FOUND,
          'Message not found',
          status: :not_found
        )

        controller.send(:resolve)
      end
    end
  end

  # A callback raising after the action rendered used to reach error_response,
  # which rendered a second time: DoubleRenderError, a generic 500, and the real
  # exception nowhere — not in the response, not in the log.
  describe 'error handling once the action has already responded' do
    let(:exception) { ActiveRecord::RecordInvalid.new(Message.new) }

    it 'renders the validation error when nothing has been rendered yet' do
      allow(controller).to receive(:performed?).and_return(false)
      allow(controller).to receive(:format_validation_errors).and_return([])

      expect(controller).to receive(:render).with(
        hash_including(status: :unprocessable_entity)
      )

      controller.send(:handle_record_invalid, exception)
    end

    it 'does not render a second time, and logs the error it could not deliver' do
      allow(controller).to receive(:performed?).and_return(true)

      expect(controller).not_to receive(:render)
      expect(Rails.logger).to receive(:error).at_least(:once)

      controller.send(
        :error_response,
        ApiErrorCodes::VALIDATION_ERROR,
        'Validation failed',
        status: :unprocessable_entity
      )
    end

    it 'logs the rescued exception so it survives even when the response is gone' do
      allow(controller).to receive(:performed?).and_return(true)
      allow(controller).to receive(:format_validation_errors).and_return([])
      logged = []
      allow(Rails.logger).to receive(:error) { |message| logged << message.to_s }

      controller.send(:handle_record_invalid, exception)

      expect(logged.join("\n")).to include('ActiveRecord::RecordInvalid')
    end
  end
end
