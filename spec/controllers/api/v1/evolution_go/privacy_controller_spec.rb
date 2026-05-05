# frozen_string_literal: true

require 'rails_helper'

# Pins that PrivacyController#set_instance_params uses the EvolutionGoConcern
# credential helper for legacy channels (EVO-984).
RSpec.describe Api::V1::EvolutionGo::PrivacyController, type: :controller do
  describe '#set_instance_params (channel branch)' do
    let(:controller_instance) { described_class.new }
    let(:channel) do
      instance_double(
        Channel::Whatsapp,
        id: 'chan-uuid',
        provider_config: { 'api_url' => '', 'admin_token' => '', 'instance_token' => 'inst-tok',
                           'instance_uuid' => 'inst-uuid', 'instance_name' => 'inst-name' },
        inbox: instance_double(Inbox)
      )
    end

    before do
      controller_instance.params = ActionController::Parameters.new(id: 'inst-uuid')
      relation = double('relation')
      allow(Channel::Whatsapp).to receive(:joins).with(:inbox).and_return(relation)
      allow(relation).to receive(:where).and_return(relation)
      allow(relation).to receive(:first).and_return(channel)
    end

    it 'falls back to GlobalConfig for api_url and admin_token when provider_config is blank' do
      allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://global.example.com')
      allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('global-secret')

      controller_instance.send(:set_instance_params)

      expect(controller_instance.instance_variable_get(:@api_url)).to eq('http://global.example.com')
      expect(controller_instance.instance_variable_get(:@admin_token)).to eq('global-secret')
      expect(controller_instance.instance_variable_get(:@instance_token)).to eq('inst-tok')
    end
  end
end
