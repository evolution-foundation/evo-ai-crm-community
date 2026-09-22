# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Pipelines::StageMessageActions do
  let(:host) { Class.new { include Pipelines::StageMessageActions }.new }
  let(:pipeline_owner) { User.create!(name: 'Pipeline Owner', email: "owner-#{SecureRandom.hex(4)}@test.com") }
  let(:pipeline) { Pipeline.create!(name: 'Test Pipeline', pipeline_type: 'custom', created_by: pipeline_owner) }
  let(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'Stage A', position: 1) }
  let(:contact) { Contact.create!(name: 'Contact', email: "contact-#{SecureRandom.hex(4)}@test.com") }
  let(:pipeline_item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, contact: contact) }

  after { Current.user = nil }

  describe '#create_pipeline_task' do
    it "falls back to the pipeline's own creator, not an arbitrary global user (EVO-659)" do
      # Created before pipeline_owner, so it would be User.first globally — but has
      # no relationship to this pipeline. The old fallback (Current.user || User.first)
      # credited the task to whichever user happens to sort first account-wide, a
      # stranger on a shared install.
      stranger = User.create!(name: 'Stranger', email: "stranger-#{SecureRandom.hex(4)}@test.com")
      expect(User.first).to eq(stranger)

      Current.user = nil
      host.send(:create_pipeline_task, pipeline_item, 'Follow up')

      task = pipeline_item.tasks.last
      expect(task.created_by).to eq(pipeline_owner)
      expect(task.created_by).not_to eq(stranger)
    end

    it 'prefers Current.user when one is present' do
      current = User.create!(name: 'Current Agent', email: "current-#{SecureRandom.hex(4)}@test.com")

      Current.user = current
      host.send(:create_pipeline_task, pipeline_item, 'Follow up')

      expect(pipeline_item.tasks.last.created_by).to eq(current)
    end
  end
end
