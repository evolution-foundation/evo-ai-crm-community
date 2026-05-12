# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AutomationRules::ConditionsFilterService do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def build_rule(conditions:, event_name: 'conversation_updated')
    rule = AutomationRule.new(
      name: "rule-#{SecureRandom.hex(4)}",
      event_name: event_name,
      active: true,
      mode: 'simple',
      conditions: conditions,
      actions: [{ 'action_name' => 'send_message', 'action_params' => ['hi'] }]
    )
    rule.save!(validate: false)
    rule
  end

  describe '#perform with attribute_changed on scalar attributes' do
    let(:conditions) do
      [{
        'attribute_key' => 'status',
        'filter_operator' => 'attribute_changed',
        'values' => { 'from' => ['open'], 'to' => ['resolved'] },
        'query_operator' => nil
      }]
    end
    let(:rule) { build_rule(conditions: conditions) }

    it 'matches when previous and current are inside from/to' do
      service = described_class.new(rule, conversation, changed_attributes: { 'status' => %w[open resolved] })
      expect(service.perform).to be(true)
    end

    it 'does not match when previous is not in from' do
      service = described_class.new(rule, conversation, changed_attributes: { 'status' => %w[snoozed resolved] })
      expect(service.perform).to be(false)
    end

    it 'does not match when current is not in to' do
      service = described_class.new(rule, conversation, changed_attributes: { 'status' => %w[open snoozed] })
      expect(service.perform).to be(false)
    end

    it 'does not match (and does not crash) when the watched attribute was not in this update' do
      service = described_class.new(rule, conversation, changed_attributes: { 'priority' => [nil, 'urgent'] })
      expect(service.perform).to be(false)
    end
  end

  # Regression guard for review finding M1: empty from/to on scalar attributes
  # used to fall through to `Array.in?([])` which is always false, so the rule
  # could never fire. Empty now behaves as a wildcard, mirroring
  # labels_transition_match? semantics.
  describe '#perform with attribute_changed wildcard semantics on scalars' do
    it 'treats empty `from` as wildcard ("any value -> resolved")' do
      conditions = [{
        'attribute_key' => 'status',
        'filter_operator' => 'attribute_changed',
        'values' => { 'from' => [], 'to' => ['resolved'] },
        'query_operator' => nil
      }]
      rule = build_rule(conditions: conditions)
      service = described_class.new(rule, conversation, changed_attributes: { 'status' => %w[snoozed resolved] })
      expect(service.perform).to be(true)
    end

    it 'treats empty `to` as wildcard ("open -> any value")' do
      conditions = [{
        'attribute_key' => 'status',
        'filter_operator' => 'attribute_changed',
        'values' => { 'from' => ['open'], 'to' => [] },
        'query_operator' => nil
      }]
      rule = build_rule(conditions: conditions)
      service = described_class.new(rule, conversation, changed_attributes: { 'status' => %w[open snoozed] })
      expect(service.perform).to be(true)
    end

    it 'still requires the matching side to be in the list when non-empty' do
      conditions = [{
        'attribute_key' => 'status',
        'filter_operator' => 'attribute_changed',
        'values' => { 'from' => [], 'to' => ['resolved'] },
        'query_operator' => nil
      }]
      rule = build_rule(conditions: conditions)
      service = described_class.new(rule, conversation, changed_attributes: { 'status' => %w[snoozed open] })
      expect(service.perform).to be(false)
    end
  end

  describe '#perform with attribute_changed on labels (Pedro pilot path)' do
    let!(:label_atleta) { Label.create!(title: 'atleta', color: '#abcdef') }

    context 'when from is empty and to contains a label (= "label was added")' do
      let(:conditions) do
        [{
          'attribute_key' => 'labels',
          'filter_operator' => 'attribute_changed',
          'values' => { 'from' => [], 'to' => [label_atleta.id] },
          'query_operator' => nil
        }]
      end
      let(:rule) { build_rule(conditions: conditions) }

      it 'matches when the requested label appears in the diff (added)' do
        service = described_class.new(rule, conversation, changed_attributes: { 'label_list' => [[], ['atleta']] })
        expect(service.perform).to be(true)
      end

      it 'does not match when a different label was added' do
        service = described_class.new(rule, conversation, changed_attributes: { 'label_list' => [[], ['other']] })
        expect(service.perform).to be(false)
      end

      it 'does not match when the label already existed and a different one was added (no transition for atleta)' do
        service = described_class.new(rule, conversation, changed_attributes: { 'label_list' => [['atleta'], %w[atleta other]] })
        expect(service.perform).to be(false)
      end
    end

    context 'when from contains a label and to is empty (= "label was removed")' do
      let(:conditions) do
        [{
          'attribute_key' => 'labels',
          'filter_operator' => 'attribute_changed',
          'values' => { 'from' => [label_atleta.id], 'to' => [] },
          'query_operator' => nil
        }]
      end
      let(:rule) { build_rule(conditions: conditions) }

      it 'matches when the requested label disappears from the diff' do
        service = described_class.new(rule, conversation, changed_attributes: { 'label_list' => [['atleta'], []] })
        expect(service.perform).to be(true)
      end
    end

    context 'with concurrent label changes (multiple labels added in the same update)' do
      let(:conditions) do
        [{
          'attribute_key' => 'labels',
          'filter_operator' => 'attribute_changed',
          'values' => { 'from' => [], 'to' => [label_atleta.id] },
          'query_operator' => nil
        }]
      end
      let(:rule) { build_rule(conditions: conditions) }

      it 'matches when the watched label appears among several newly added labels' do
        service = described_class.new(rule, conversation, changed_attributes: { 'label_list' => [[], %w[atleta urgent vip]] })
        expect(service.perform).to be(true)
      end

      it 'does not match when the watched label is unchanged but other labels are added' do
        service = described_class.new(rule, conversation, changed_attributes: { 'label_list' => [['atleta'], %w[atleta urgent vip]] })
        expect(service.perform).to be(false)
      end
    end
  end

  describe '#perform with attribute_changed on scalar attributes other than status' do
    let!(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }

    it 'matches a priority transition' do
      conditions = [{
        'attribute_key' => 'priority',
        'filter_operator' => 'attribute_changed',
        'values' => { 'from' => [nil], 'to' => ['urgent'] },
        'query_operator' => nil
      }]
      rule = build_rule(conditions: conditions)
      service = described_class.new(rule, conversation, changed_attributes: { 'priority' => [nil, 'urgent'] })
      expect(service.perform).to be(true)
    end

    it 'matches an assignee_id transition' do
      conditions = [{
        'attribute_key' => 'assignee_id',
        'filter_operator' => 'attribute_changed',
        'values' => { 'from' => [nil], 'to' => [user.id] },
        'query_operator' => nil
      }]
      rule = build_rule(conditions: conditions)
      service = described_class.new(rule, conversation, changed_attributes: { 'assignee_id' => [nil, user.id] })
      expect(service.perform).to be(true)
    end
  end

  # Regression guard for the H1 finding in the review of PR #56: pipeline_stage_id
  # falls into pipeline_operation_valid? (not operation_valid?), so the
  # special-case for attribute_changed on line 65 of ConditionValidationService
  # did not apply. The rule was getting rejected by rule_valid? before any
  # matching ran. Fixed by adding attribute_changed to the allowed operator
  # list in pipeline_operation_valid?.
  describe '#perform with attribute_changed on pipeline_stage_id' do
    let(:pipeline_owner) do
      User.first || User.create!(name: 'Owner', email: "o-#{SecureRandom.hex(4)}@test.com")
    end
    let(:pipeline) { Pipeline.create!(name: 'P', pipeline_type: 'custom', created_by: pipeline_owner) }
    let!(:stage_a) { PipelineStage.create!(pipeline: pipeline, name: 'A', position: 1) }
    let!(:stage_b) { PipelineStage.create!(pipeline: pipeline, name: 'B', position: 2) }

    it 'is accepted by the validation service (not silently rejected by rule_valid?)' do
      conditions = [{
        'attribute_key' => 'pipeline_stage_id',
        'filter_operator' => 'attribute_changed',
        'values' => { 'from' => [stage_a.id], 'to' => [stage_b.id] },
        'query_operator' => nil
      }]
      rule = build_rule(conditions: conditions, event_name: 'pipeline_stage_updated')

      expect(AutomationRules::ConditionValidationService.new(rule).perform).to be(true)
    end

    it 'fires once on the stage transition' do
      conditions = [{
        'attribute_key' => 'pipeline_stage_id',
        'filter_operator' => 'attribute_changed',
        'values' => { 'from' => [stage_a.id], 'to' => [stage_b.id] },
        'query_operator' => nil
      }]
      rule = build_rule(conditions: conditions, event_name: 'pipeline_stage_updated')
      service = described_class.new(rule, conversation, changed_attributes: { 'pipeline_stage_id' => [stage_a.id, stage_b.id] })
      expect(service.perform).to be(true)
    end
  end
end
