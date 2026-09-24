# frozen_string_literal: true

require 'rails_helper'

# EVO-1932: regression coverage for the journey add-label/remove-label path.
# The bug class is a label write that returns success but persists NO tagging
# (`taggings.count == 0`). These specs assert PERSISTENCE through the public
# `update_labels`/`add_labels`/`remove_labels` API — i.e. the assignment
# (setter) path that `acts_as_taggable_on` dirty-tracks — rather than the
# in-place `label_list.add` mutation, since the setter path is the one every
# real caller (LabelConcern#create, journeys, bulk actions) actually uses.
RSpec.describe Labelable, type: :model do
  # Contact is the model the journey label nodes write to and includes
  # Labelable. Using a real persisted record exercises the gem end to end.
  let(:contact) do
    Contact.create!(name: 'Labelable Spec', email: "labelable-#{SecureRandom.hex(4)}@example.com")
  end

  describe '#update_labels' do
    it 'persists a tagging on a contact that had none (primary AC)' do
      contact.update_labels(['teste label'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.taggings.count).to be >= 1
      expect(reloaded.label_list).to contain_exactly('teste label')
    end

    it 'is idempotent — re-applying the same label does not duplicate taggings' do
      contact.update_labels(['teste label'])
      contact.update_labels(['teste label'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.taggings.count).to eq(1)
      expect(reloaded.label_list).to contain_exactly('teste label')
    end

    it 'REPLACES the existing set' do
      contact.update_labels(['old'])
      contact.update_labels(['new'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.label_list).to contain_exactly('new')
      expect(reloaded.taggings.count).to eq(1)
    end

    it 'clears the set when given an empty array (re-post removal)' do
      contact.update_labels(['gone-soon'])
      contact.update_labels([])

      reloaded = Contact.find(contact.id)
      expect(reloaded.label_list).to be_empty
      expect(reloaded.taggings.count).to eq(0)
    end

    it 'normalises blank/whitespace tokens away rather than persisting them' do
      contact.update_labels(['  spaced  ', '', '   ', nil])

      reloaded = Contact.find(contact.id)
      expect(reloaded.label_list).to contain_exactly('spaced')
    end
  end

  describe '#add_labels' do
    it 'does not duplicate a label sent in a different case' do
      contact.update_labels(['vip'])
      contact.add_labels(['VIP'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.label_list.map(&:downcase)).to eq(['vip'])
      expect(reloaded.taggings.count).to eq(1)
    end

    it 'persists a tagging when adding to a contact with no labels' do
      contact.add_labels(['alpha'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.taggings.count).to eq(1)
      expect(reloaded.label_list).to contain_exactly('alpha')
    end

    it 'unions with existing labels without dropping them' do
      contact.update_labels(['existing'])
      contact.add_labels(['added'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.taggings.count).to eq(2)
      expect(reloaded.label_list).to contain_exactly('existing', 'added')
    end

    it 'is idempotent — adding an already-present label does not duplicate' do
      contact.update_labels(['existing'])
      contact.add_labels(['existing'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.taggings.count).to eq(1)
      expect(reloaded.label_list).to contain_exactly('existing')
    end

    it 'accepts a bare scalar (non-array) token' do
      contact.add_labels('scalar')

      reloaded = Contact.find(contact.id)
      expect(reloaded.label_list).to contain_exactly('scalar')
    end
  end

  describe '#remove_labels' do
    it 'removes the given label and persists the smaller set' do
      contact.update_labels(%w[keep drop])
      contact.remove_labels(['drop'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.label_list).to contain_exactly('keep')
      expect(reloaded.taggings.count).to eq(1)
    end

    it 'removes a label sent in a different case' do
      contact.update_labels(%w[vip keep])
      contact.remove_labels(['VIP'])

      expect(Contact.find(contact.id).label_list).to contain_exactly('keep')
    end

    it 'is a no-op when removing a label that is not present' do
      contact.update_labels(['keep'])
      contact.remove_labels(['never-had'])

      reloaded = Contact.find(contact.id)
      expect(reloaded.label_list).to contain_exactly('keep')
    end
  end
end
