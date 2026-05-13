# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Contact, type: :model do
  let(:person_contact)  { Contact.create!(name: 'Alice', email: 'alice@example.com', type: 'person') }
  let(:company_contact) { Contact.create!(name: 'Acme Corp', type: 'company') }
  let(:group_contact)   { Contact.create!(name: 'Almoço BH', identifier: '12345-9876@g.us', type: 'group') }

  describe '#group?' do
    it 'returns true for type=group' do
      expect(group_contact.group?).to be true
    end

    it 'returns false for type=person' do
      expect(person_contact.group?).to be false
    end

    it 'returns false for type=company' do
      expect(company_contact.group?).to be false
    end
  end

  describe '.non_groups scope' do
    before { person_contact; company_contact; group_contact }

    it 'excludes contacts with type=group' do
      ids = Contact.non_groups.pluck(:id)
      expect(ids).not_to include(group_contact.id)
    end

    it 'includes person and company contacts' do
      ids = Contact.non_groups.pluck(:id)
      expect(ids).to include(person_contact.id, company_contact.id)
    end
  end

  describe '#assign_to_default_pipeline' do
    let!(:pipeline) { Pipeline.create!(name: 'Default', pipeline_type: 'sales', is_default: true, created_by: User.create!(email: 'dev@example.com', name: 'Dev')) }

    it 'skips pipeline assignment for group contacts' do
      expect { group_contact }.not_to change(PipelineItem, :count)
    end

    it 'creates a pipeline item for person contacts when a default pipeline exists' do
      expect { person_contact }.to change(PipelineItem, :count).by(1)
    end
  end
end
