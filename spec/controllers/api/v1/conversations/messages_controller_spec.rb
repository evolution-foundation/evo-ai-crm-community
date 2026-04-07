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
  describe '#normalized_message_id!' do
    subject(:normalized_message_id) { described_class.new.send(:normalized_message_id!, raw_id) }

    context 'when id is a valid uuid' do
      let(:raw_id) { '9f64ba72-3b1f-4bfe-b8bf-5f8fba9d352f' }

      it { is_expected.to eq(raw_id) }
    end

    context 'when id is blank' do
      let(:raw_id) { '   ' }

      it 'raises argument error' do
        expect { normalized_message_id }.to raise_error(ArgumentError, 'Message ID is required')
      end
    end

    context 'when id is malformed' do
      let(:raw_id) { 'invalid-id' }

      it 'raises argument error' do
        expect { normalized_message_id }.to raise_error(ArgumentError, 'Invalid message ID format. Expected UUID.')
      end
    end
  end
end
