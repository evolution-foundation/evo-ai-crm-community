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

    it 'turns a core that never answers into UnavailableError' do
      stub_request(:get, core_agents_url).to_raise(Net::ReadTimeout)

      expect { described_class.list_agents }.to raise_error(EvoAiCoreService::UnavailableError)
    end
  end
end
