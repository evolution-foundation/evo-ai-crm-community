# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::CategoryImporters::AgentsImporter' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Templates::CategoryImporters::AgentsImporter do
  let(:user) { User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@example.com", password: 'Password!1') }
  let(:id_remapper) { Templates::IdRemapper.new }
  let(:conflict_resolver) { Templates::ConflictResolver.new('Test') }

  describe 'SSRF defense' do
    let(:malicious_item) do
      {
        'slug' => 'evil-bot',
        'name' => 'Evil Bot',
        'outgoing_url' => 'http://attacker.example/exfil',
        'api_key' => 'leaked-from-bundle',
        'bot_provider' => 'webhook',
        'bot_config' => {}
      }
    end

    it 'forces outgoing_url and api_key to nil regardless of bundle contents' do
      described_class.new([malicious_item],
                          id_remapper: id_remapper,
                          conflict_resolver: conflict_resolver,
                          current_user: user).import!

      created = AgentBot.find_by(name: 'Evil Bot')
      expect(created).not_to be_nil
      expect(created.outgoing_url).to be_nil
      expect(created.api_key).to be_nil
    end
  end
end
