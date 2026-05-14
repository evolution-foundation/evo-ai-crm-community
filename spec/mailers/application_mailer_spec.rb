# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationMailer do
  describe '#apply_dynamic_delivery_settings' do
    let(:mailer) { described_class.new }
    let(:message_double) { instance_double(Mail::Message) }

    before do
      allow(mailer).to receive(:message).and_return(message_double)
    end

    context 'when delivery method is registered' do
      let(:delivery_class) { Mail::SMTP }

      before do
        mailer.instance_variable_set(:@dynamic_delivery_method, :smtp)
        mailer.instance_variable_set(:@dynamic_delivery_options, { address: 'smtp.example.com' })
        allow(described_class).to receive(:delivery_methods).and_return({ smtp: delivery_class })
        allow(message_double).to receive(:delivery_method).with(delivery_class, anything)
      end

      it 'sets the delivery method using the registered class' do
        expect(message_double).to receive(:delivery_method).with(delivery_class, anything)
        mailer.send(:apply_dynamic_delivery_settings)
      end
    end

    context 'when delivery method is not registered in delivery_methods' do
      before do
        mailer.instance_variable_set(:@dynamic_delivery_method, :unknown_provider)
        mailer.instance_variable_set(:@dynamic_delivery_options, {})
        allow(described_class).to receive(:delivery_methods).and_return({})
        allow(message_double).to receive(:delivery_method).with(anything, anything)
      end

      it 'logs a warning about the unregistered delivery method' do
        expect(Rails.logger).to receive(:warn).with(/unregistered delivery method/)
        mailer.send(:apply_dynamic_delivery_settings)
      end

      it 'falls back to passing the symbol directly' do
        expect(message_double).to receive(:delivery_method).with(:unknown_provider, anything)
        mailer.send(:apply_dynamic_delivery_settings)
      end
    end

    context 'when @dynamic_delivery_method is nil' do
      before do
        mailer.instance_variable_set(:@dynamic_delivery_method, nil)
      end

      it 'does not call message.delivery_method' do
        expect(message_double).not_to receive(:delivery_method)
        mailer.send(:apply_dynamic_delivery_settings)
      end
    end
  end
end
