# frozen_string_literal: true

begin
  require 'rails_helper'
rescue LoadError
  RSpec.describe 'Templates::CategoryImporters::MessageTemplatesImporter' do
    it 'has service spec scaffold ready' do
      skip 'rails_helper is not available in this workspace snapshot'
    end
  end
end

return unless defined?(Rails)

RSpec.describe Templates::CategoryImporters::MessageTemplatesImporter do
  let(:user) { User.create!(name: 'Admin', email: "admin-#{SecureRandom.hex(4)}@example.com") }
  let(:id_remapper) { Templates::IdRemapper.new }
  let(:conflict_resolver) { Templates::ConflictResolver.new('Clínica') }

  def import(items)
    described_class.new(items,
                        id_remapper: id_remapper,
                        conflict_resolver: conflict_resolver,
                        current_user: user).import!
  end

  describe '#import!' do
    it 'links the template to the inbox the bundle brought in' do
      inbox = Inbox.create!(name: "Suporte #{SecureRandom.hex(3)}",
                            channel: Channel::Api.create!(webhook_url: 'https://example.com/hook'))
      id_remapper.register('inboxes', 'suporte', inbox.id)

      report = import([{ 'slug' => 'boas-vindas', 'inbox_slug' => 'suporte',
                         'name' => "boas-vindas-#{SecureRandom.hex(3)}", 'content' => 'Oi' }])

      expect(report.first['status']).to eq('created')
      expect(MessageTemplate.find(report.first['new_id']).channel_id).to eq(inbox.channel_id)
    end

    it 'names the slug it could not resolve' do
      report = import([{ 'slug' => 'boas-vindas', 'inbox_slug' => 'suporte', 'name' => 'boas-vindas', 'content' => 'Oi' }])

      expect(report.first['status']).to eq('skipped')
      expect(report.first['reason']).to eq("inbox slug 'suporte' not found in import set")
    end

    # A blank slug is not a lookup miss, and quoting it as one sent the operator
    # hunting for an inbox named ''.
    it 'says the bundle named no inbox when the slug is blank' do
      report = import([{ 'slug' => 'boas-vindas', 'inbox_slug' => nil, 'name' => 'boas-vindas', 'content' => 'Oi' }])

      expect(report.first['status']).to eq('skipped')
      expect(report.first['reason']).to eq('the bundle names no inbox for this template')
    end
  end
end
