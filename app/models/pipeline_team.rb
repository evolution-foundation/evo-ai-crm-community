# frozen_string_literal: true

# == Schema Information
#
# Table name: pipeline_teams
#
#  id          :uuid             not null, primary key
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  pipeline_id :uuid             not null
#  team_id     :uuid             not null
#
# Indexes
#
#  index_pipeline_teams_on_pipeline_id_and_team_id  (pipeline_id,team_id) UNIQUE
#  index_pipeline_teams_on_team_id                  (team_id)
#
# Foreign Keys
#
#  fk_rails_...  (pipeline_id => pipelines.id)
#  fk_rails_...  (team_id => teams.id)
#
# EVO-2222: join between a `team`-visible pipeline and the teams it is shared with.
# The pipeline's members-with-access are the members of these teams.
class PipelineTeam < ApplicationRecord
  belongs_to :pipeline
  belongs_to :team

  # Mirrors the unique index so a repeated team surfaces as a validation error instead
  # of RecordNotUnique.
  validates :team_id, uniqueness: { scope: :pipeline_id }
end
