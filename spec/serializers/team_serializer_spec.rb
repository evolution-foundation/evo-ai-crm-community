# frozen_string_literal: true

require 'rails_helper'

RSpec.describe TeamSerializer do
  let(:team) { Team.create!(name: "Spec Team #{SecureRandom.hex(4)}") }

  describe '.serialize' do
    it 'reports members_count as 0 for an empty team' do
      result = described_class.serialize(team)
      expect(result[:members_count]).to eq(0)
    end

    it 'reports members_count matching the number of team_members' do
      user_a = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", name: 'Alpha')
      user_b = User.create!(email: "b-#{SecureRandom.hex(4)}@example.com", name: 'Bravo')
      team.add_members([user_a.id, user_b.id])

      result = described_class.serialize(team)

      expect(result[:members_count]).to eq(2)
    end

    it 'includes members_count in the collection serializer output' do
      user = User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", name: 'Charlie')
      team.add_members([user.id])

      result = described_class.serialize_collection([team])

      expect(result.first[:members_count]).to eq(1)
    end
  end
end
