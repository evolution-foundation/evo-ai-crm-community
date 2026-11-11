# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Procedure, type: :model do
  let(:user) { User.create!(email: "procedure-user-#{SecureRandom.hex(4)}@example.com", name: 'Procedure User') }

  before do
    Current.evo_role_key = 'agent'
  end

  after { Current.reset }

  describe '.visible_to' do
    it 'returns published procedures visible to all agents' do
      procedure = Procedure.create!(
        title: 'Troca de titularidade',
        description: 'Passo a passo interno',
        category: 'Suporte',
        status: :published,
        usage_mode: :internal,
        content_blocks: [{ id: '1', type: 'paragraph', text: 'Validar dados' }]
      )
      procedure.procedure_visibilities.create!(scope_type: 'all')

      expect(described_class.visible_to(user)).to include(procedure)
    end

    it 'does not return drafts to regular agents' do
      procedure = Procedure.create!(
        title: 'Rascunho',
        status: :draft,
        usage_mode: :internal,
        content_blocks: []
      )
      procedure.procedure_visibilities.create!(scope_type: 'all')

      expect(described_class.visible_to(user)).not_to include(procedure)
    end

    it 'does not treat public-link-only procedures as internally visible' do
      procedure = Procedure.create!(
        title: 'Link para cliente',
        status: :published,
        usage_mode: :customer,
        content_blocks: []
      )
      procedure.procedure_visibilities.create!(scope_type: 'public_link')

      expect(described_class.visible_to(user)).not_to include(procedure)
    end
  end
end
