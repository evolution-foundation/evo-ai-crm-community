# frozen_string_literal: true

# Shared by Api::V1::KnowledgeBasesController#search and
# Api::V1::Internal::KnowledgeController#search. Both pass max_results
# straight into KnowledgeEntry.search's `.limit()`; a negative value raises
# PG::Error ("LIMIT must not be negative"), and the shipped frontend's number
# input allows 0/negative to reach the API. Clamp to a sane [1, 50] range.
module KnowledgeSearchParams
  extend ActiveSupport::Concern

  private

  def clamped_max_results(default:)
    [[(params[:max_results] || default).to_i, 1].max, 50].min
  end
end
