# frozen_string_literal: true

# TeamSerializer - Optimized serialization for Team resources
#
# Plain Ruby module for Oj direct serialization
#
# Usage:
#   TeamSerializer.serialize(@team, include_members: true)
#
module TeamSerializer
  extend self

  # Serialize single Team with optimized field selection
  #
  # @param team [Team] Team to serialize
  # @param options [Hash] Serialization options
  # @option options [Boolean] :include_members Include team members
  # @option options [Integer] :current_user_id Current user ID to check membership
  #
  # @return [Hash] Serialized team ready for Oj
  #
  def serialize(team, include_members: false, current_user_id: nil)
    result = {
      id: team.id,
      name: team.name,
      description: team.description,
      allow_auto_assign: team.allow_auto_assign,
      members_count: team.team_members.count,
      created_at: team.created_at.to_i,
      updated_at: team.updated_at.to_i
    }

    # Check if current user is member
    if current_user_id
      result['is_member'] = team.team_members.exists?(user_id: current_user_id)
    end

    # Include members
    if include_members
      result['members'] = team.members.map do |member|
        UserSerializer.serialize(member)
      end
    end

    result
  end

  # Serialize collection of Teams
  #
  # @param teams [Array<Team>, ActiveRecord::Relation]
  # @param options [Hash] Same options as serialize method
  #
  # @return [Array<Hash>] Array of serialized teams
  #
  def serialize_collection(teams, **options)
    return [] unless teams

    teams.map { |team| serialize(team, **options) }
  end
end
