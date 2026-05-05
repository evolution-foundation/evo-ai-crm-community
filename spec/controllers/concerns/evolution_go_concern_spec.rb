# frozen_string_literal: true

require 'rails_helper'

# Unit-level coverage for EvolutionGoConcern's credential resolution. Older
# Evolution Go channels created before the provider_config persistence fix may
# still have empty api_url/admin_token in their config — controllers must fall
# back to GlobalConfigService so QR generation / settings / privacy / profile
# endpoints stop failing for those channels.
RSpec.describe EvolutionGoConcern, type: :concern do
  let(:host_class) do
    Class.new do
      include EvolutionGoConcern

      public :evolution_go_credentials_for
    end
  end

  let(:host) { host_class.new }

  describe '#evolution_go_credentials_for' do
    context 'when provider_config has the credentials' do
      it 'returns the channel values without consulting GlobalConfig' do
        expect(GlobalConfigService).not_to receive(:load).with('EVOLUTION_GO_API_URL', anything)
        expect(GlobalConfigService).not_to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', anything)

        channel = instance_double(
          Channel::Whatsapp,
          provider_config: {
            'api_url' => 'http://channel.example.com',
            'admin_token' => 'channel-token',
            'instance_token' => 'instance-token',
            'instance_uuid' => 'uuid-1',
            'instance_name' => 'instance-name'
          }
        )

        creds = host.evolution_go_credentials_for(channel)

        expect(creds[:api_url]).to eq('http://channel.example.com')
        expect(creds[:admin_token]).to eq('channel-token')
        expect(creds[:instance_token]).to eq('instance-token')
        expect(creds[:instance_uuid]).to eq('uuid-1')
        expect(creds[:instance_name]).to eq('instance-name')
      end
    end

    context 'when provider_config is missing api_url and admin_token' do
      it 'falls back to GlobalConfigService for api_url and admin_token' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://global.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('global-secret')

        channel = instance_double(
          Channel::Whatsapp,
          provider_config: {
            'instance_token' => 'instance-token',
            'instance_uuid' => 'uuid-1'
          }
        )

        creds = host.evolution_go_credentials_for(channel)

        expect(creds[:api_url]).to eq('http://global.example.com')
        expect(creds[:admin_token]).to eq('global-secret')
        expect(creds[:instance_token]).to eq('instance-token')
      end
    end

    context 'when provider_config has values but they are blank strings' do
      it 'still falls back to GlobalConfigService' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://global.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('global-secret')
        allow(Rails.logger).to receive(:warn)

        channel = instance_double(
          Channel::Whatsapp,
          id: 'chan-uuid',
          provider_config: { 'api_url' => '', 'admin_token' => '   ' }
        )

        creds = host.evolution_go_credentials_for(channel)

        expect(creds[:api_url]).to eq('http://global.example.com')
        expect(creds[:admin_token]).to eq('global-secret')
      end
    end

    context 'when neither provider_config nor GlobalConfig has values' do
      it 'returns empty strings without raising' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('')
        allow(Rails.logger).to receive(:warn)

        channel = instance_double(Channel::Whatsapp, id: 'chan-uuid', provider_config: {})

        creds = host.evolution_go_credentials_for(channel)

        expect(creds[:api_url]).to eq('')
        expect(creds[:admin_token]).to eq('')
      end
    end

    context 'when channel is nil' do
      it 'returns the GlobalConfig values without raising' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://global.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('global-secret')

        creds = host.evolution_go_credentials_for(nil)

        expect(creds[:api_url]).to eq('http://global.example.com')
        expect(creds[:admin_token]).to eq('global-secret')
        expect(creds[:instance_token]).to be_nil
      end

      it 'does not warn (no channel to attribute the inconsistency to)' do
        allow(GlobalConfigService).to receive(:load).and_return('')
        expect(Rails.logger).not_to receive(:warn)

        host.evolution_go_credentials_for(nil)
      end
    end

    context 'when channel is present but instance_token is blank (corrupt channel)' do
      it 'logs a warning so production occurrences are observable' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://global.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('global-secret')

        channel = instance_double(
          Channel::Whatsapp,
          id: 'chan-uuid',
          provider_config: { 'instance_uuid' => 'uuid-1' }
        )

        expect(Rails.logger).to receive(:warn).with(/channel chan-uuid resolved with missing instance credentials/)

        host.evolution_go_credentials_for(channel)
      end
    end
  end
end
