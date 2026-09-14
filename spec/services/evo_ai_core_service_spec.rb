# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

RSpec.describe EvoAiCoreService do
  describe 'HTTP timeouts' do
    let(:core_agents_url) { %r{\A#{Regexp.escape(described_class.base_uri)}/api/v1/agents} }

    it 'connects to evo-core with the configured timeouts and no silent retry' do
      stub_request(:get, core_agents_url).to_return(status: 200, body: '[]')
      connections = []
      allow(Net::HTTP).to receive(:new).and_wrap_original do |original, *args|
        original.call(*args).tap { |http| connections << http }
      end

      described_class.list_agents

      expect(connections.map { |http| [http.open_timeout, http.read_timeout, http.max_retries] }).to eq([[5, 15, 0]])
    end

    describe 'reading the timeout from the environment' do
      def timeout_for(value)
        ClimateControl.modify(EVO_AI_CORE_READ_TIMEOUT: value) do
          described_class.send(:timeout_from_env, 'EVO_AI_CORE_READ_TIMEOUT', 15)
        end
      end

      it 'uses the default when the variable is unset or blank' do
        expect([timeout_for(nil), timeout_for(''), timeout_for('  ')]).to eq([15, 15, 15])
      end

      it 'uses a positive integer as given' do
        expect(timeout_for('30')).to eq(30)
      end

      it 'refuses a value that would become a zero or negative timeout' do
        %w[abc 0 -5 1.5].each do |value|
          expect { timeout_for(value) }.to raise_error(ArgumentError, /EVO_AI_CORE_READ_TIMEOUT/)
        end
      end
    end

    it 'turns a core that never answers into UnavailableError' do
      stub_request(:get, core_agents_url).to_raise(Net::ReadTimeout)

      expect { described_class.list_agents }.to raise_error(EvoAiCoreService::UnavailableError)
    end
  end
end
