# frozen_string_literal: true

require 'rails_helper'

# Unit-level coverage for the eager webhook subscription added on Evolution Go
# instance creation. The /instance/connect call is what registers the CRM as
# webhook receiver in Evolution Go — running it right after /instance/create
# means messages from the connected device flow even before the user opens the
# QR screen. A failure here MUST NOT regress the create response, since the
# QR flow re-runs the same call later and would retry the registration.
RSpec.describe Api::V1::EvolutionGo::AuthorizationsController, type: :controller do
  describe '#register_webhook_after_create' do
    let(:controller_instance) { described_class.new }
    let(:api_url) { 'http://evo.example.com' }
    let(:instance_token) { 'instance-token-123' }

    it 'invokes connect_instance with the freshly created instance credentials' do
      expect(controller_instance).to receive(:connect_instance).with(api_url, instance_token)

      controller_instance.send(:register_webhook_after_create, api_url, instance_token)
    end

    it 'swallows errors raised by connect_instance and logs them' do
      allow(controller_instance).to receive(:connect_instance).and_raise(StandardError.new('BACKEND_URL is not configured'))
      expect(Rails.logger).to receive(:error).with(/Eager webhook registration failed/)

      expect do
        controller_instance.send(:register_webhook_after_create, api_url, instance_token)
      end.not_to raise_error
    end

    it 'skips the call entirely when api_url is blank' do
      expect(controller_instance).not_to receive(:connect_instance)

      controller_instance.send(:register_webhook_after_create, '', instance_token)
    end

    it 'skips the call entirely when instance_token is blank' do
      expect(controller_instance).not_to receive(:connect_instance)

      controller_instance.send(:register_webhook_after_create, api_url, nil)
    end
  end

  # Pins the wire-up: a refactor that drops the register_webhook_after_create
  # call from #create would silently regress EVO-984 (instance has no webhook
  # until QR is opened) and the unit test above would still pass.
  describe '#create wiring' do
    let(:controller_instance) { described_class.new }

    before do
      controller_instance.params = ActionController::Parameters.new(
        authorization: { mode: 'create', api_url: 'http://evo.example.com', admin_token: 'admin-tok', instance_name: 'inst-name' }
      )
      controller_instance.instance_variable_set(:@api_url, 'http://evo.example.com')
      controller_instance.instance_variable_set(:@admin_token, 'admin-tok')
      controller_instance.instance_variable_set(:@instance_name, 'inst-name')

      allow(controller_instance).to receive(:create_instance_go).and_return(
        'instance_token' => 'tok-from-create',
        'instance_uuid' => 'uuid-from-create',
        'data' => {}
      )
      allow(controller_instance).to receive(:render)
    end

    it 'invokes register_webhook_after_create with the freshly created instance_token' do
      expect(controller_instance).to receive(:register_webhook_after_create).with('http://evo.example.com', 'tok-from-create')

      controller_instance.create
    end
  end
end
