# frozen_string_literal: true

require 'rails_helper'

# A label tagging must never exist without its catalog entry, and it
# must be stored in the catalog's own form.
RSpec.describe Labelable, type: :model do
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }

  describe 'catalog is kept in sync with what gets tagged' do
    it 'creates the missing Label when a title is applied for the first time' do
      expect { contact.update!(label_list: ['suporte premium']) }
        .to change { Label.where(title: 'suporte premium').count }.from(0).to(1)

      expect(contact.reload.label_list).to include('suporte premium')
    end

    it 'reuses the existing Label instead of creating a second one' do
      Label.create!(title: 'vip')

      expect { contact.update!(label_list: ['vip']) }.not_to change(Label, :count)
    end

    # The gem matches an existing tag ignoring case but creates it verbatim, so a
    # raw "Urgente" tag would capture every later application of "urgente".
    it 'stores the tag in the catalog form when the input differs by case' do
      Label.create!(title: 'urgente')

      contact.update!(label_list: ['Urgente'])

      expect(contact.reload.label_list).to eq(['urgente'])
      expect(ActsAsTaggableOn::Tag.pluck(:name)).to eq(['urgente'])
      expect(Label.where(title: 'urgente').count).to eq(1)
    end

    it 'trims surrounding whitespace before cataloguing' do
      contact.update!(label_list: ['  espacos  '])

      expect(contact.reload.label_list).to eq(['espacos'])
      expect(Label.exists?(title: 'espacos')).to be(true)
    end

    it 'applies through add_labels too' do
      contact.update!(label_list: ['um'])
      contact.add_labels(['dois'])

      expect(contact.reload.label_list).to match_array(%w[um dois])
      expect(Label.pluck(:title)).to match_array(%w[um dois])
    end

    # Dropping a title `Label` rejects would answer success having tagged nothing.
    it 'still applies a title the catalog cannot accept, without raising' do
      expect { contact.update!(label_list: ['a/b']) }.not_to raise_error

      expect(contact.reload.label_list).to eq(['a/b'])
      expect(Label.exists?(title: 'a/b')).to be(false)
    end

    # An id that no longer resolves arrives as a literal: applied, never promoted.
    it 'applies an unresolved id without putting a UUID in the catalog' do
      uuid = '11111111-2222-3333-4444-555555555555'

      expect { contact.update!(label_list: [uuid]) }.not_to change(Label, :count)

      expect(contact.reload.label_list).to eq([uuid])
      expect(Label.exists?(title: uuid)).to be(false)
    end

    # Applying a title catalogues it, so POST /api/v1/labels with it answers 422.
    it 'makes a later create of the same title collide, because it now exists' do
      contact.update!(label_list: ['ja existe'])

      duplicate = Label.new(title: 'ja existe')

      expect(duplicate.save).to be(false)
      expect(duplicate.errors[:title]).to be_present
    end

    # Contact and Conversation share one catalog, so pinning the second model
    # proves the override sits on the shared write path, not on one model.
    it 'applies to a conversation too, not only a contact' do
      channel = Channel::WebWidget.create!(website_url: 'https://test.example.com')
      inbox = Inbox.create!(name: 'Test Inbox', channel: channel)
      contact_inbox = ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4))
      conversation = Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox)

      conversation.update!(label_list: ['Da Conversa'])

      expect(conversation.reload.label_list).to eq(['da conversa'])
      expect(Label.exists?(title: 'da conversa')).to be(true)
    end

    # Product includes the same concern but its labels are free text typed per
    # product and imported in bulk. Cataloguing them would put every product
    # label in the contact and conversation picker, and change their casing.
    it 'leaves product labels out of the catalog, verbatim' do
      product = Product.create!(name: 'Base', kind: 'physical', default_price: 10, currency: 'BRL')

      product.update_labels(['Promocao de Verao'])

      expect(product.reload.label_list.to_a).to eq(['Promocao de Verao'])
      expect(Label.exists?(title: 'promocao de verao')).to be(false)
    end

    # The gem splits a token on commas after the setter has seen it.
    it 'catalogues each title a comma-separated token becomes' do
      contact.update!(label_list: ['Cliente, VIP'])

      expect(contact.reload.label_list).to match_array(%w[cliente vip])
      expect(Label.pluck(:title)).to match_array(%w[cliente vip])
    end

    it 'keeps a quoted title whole, as the gem does' do
      contact.update!(label_list: '"a, b", c')

      expect(contact.reload.label_list).to contain_exactly('a, b', 'c')
    end

    # A rename takes the title out of the catalog before its job reaches every
    # record; a write on one of those in between must not bring it back.
    it 'does not re-catalogue a title the record already carries' do
      contact.update!(label_list: ['antigo'])
      Label.find_by!(title: 'antigo').update!(title: 'renomeado')

      contact.add_labels(['novo'])

      expect(Label.exists?(title: 'antigo')).to be(false)
      expect(Label.exists?(title: 'novo')).to be(true)
    end
  end
end
