# frozen_string_literal: true

require 'rails_helper'

# The screen advertises "2d, 1w" for the create_pipeline_task due date. The parser is
# shared by ActionService and FlowExecutionService, so both surfaces are covered here.
RSpec.describe 'Automation rule create_pipeline_task due_in parsing' do
  let(:user) { User.create!(name: 'Agent', email: "agent-#{SecureRandom.hex(4)}@test.com") }
  let(:channel) { Channel::WebWidget.create!(website_url: 'https://test.example.com') }
  let(:inbox) { Inbox.create!(name: 'Test Inbox', channel: channel) }
  let(:contact) { Contact.create!(name: 'Contact', email: "c-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let(:pipeline) { Pipeline.create!(name: 'Board', pipeline_type: 'custom', created_by: user) }
  let!(:stage) { PipelineStage.create!(pipeline: pipeline, name: 'S1', position: 1) }
  let!(:pipeline_item) { PipelineItem.create!(pipeline: pipeline, pipeline_stage: stage, conversation: conversation) }

  after { Current.reset }

  def rule_with(due_in)
    # task_type/priority are passed explicitly, so nil would override the column default.
    params = { 'title' => 'Call the customer', 'task_type' => 'call', 'priority' => 'medium' }
    params['due_in'] = due_in unless due_in.nil?

    AutomationRule.create!(
      name: "Rule #{SecureRandom.hex(3)}",
      event_name: 'conversation_created',
      conditions: [],
      actions: [{ 'action_name' => 'create_pipeline_task', 'action_params' => [params] }],
      active: true
    )
  end

  def run(due_in)
    AutomationRules::ActionService.new(rule_with(due_in), nil, conversation).perform
    pipeline_item.reload.tasks.last
  end

  describe 'the compact format the screen advertises' do
    it 'reads "2d" as two days from now' do
      expect(run('2d').due_date).to be_within(60.seconds).of(2.days.from_now)
    end

    it 'reads "1w" as one week from now' do
      expect(run('1w').due_date).to be_within(60.seconds).of(1.week.from_now)
    end

    it 'reads "3h" as three hours from now' do
      expect(run('3h').due_date).to be_within(60.seconds).of(3.hours.from_now)
    end

    it 'reads "30min" as thirty minutes from now' do
      expect(run('30min').due_date).to be_within(60.seconds).of(30.minutes.from_now)
    end

    it 'reads "6mo" as six months from now' do
      expect(run('6mo').due_date).to be_within(60.seconds).of(6.months.from_now)
    end

    it 'reads "1y" as one year from now' do
      expect(run('1y').due_date).to be_within(60.seconds).of(1.year.from_now)
    end

    it 'accepts the spelled-out unit ("2 weeks")' do
      expect(run('2 weeks').due_date).to be_within(60.seconds).of(2.weeks.from_now)
    end

    it 'is case-insensitive and tolerates a space ("2 D")' do
      expect(run('2 D').due_date).to be_within(60.seconds).of(2.days.from_now)
    end

    it 'tolerates whitespace around the value' do
      expect(run('  5d  ').due_date).to be_within(60.seconds).of(5.days.from_now)
    end

    it 'refuses the ambiguous bare "m" instead of guessing minutes or months' do
      expect { run('30m') }.not_to(change { pipeline_item.reload.tasks.count })
    end
  end

  describe 'the formats that already worked' do
    it 'still reads an absolute date' do
      target = 10.days.from_now.to_date

      expect(run(target.to_s).due_date.to_date).to eq(target)
    end

    it 'still reads the dotted Ruby duration "3.days"' do
      expect(run('3.days').due_date).to be_within(60.seconds).of(3.days.from_now)
    end

    it 'still reads "1.week"' do
      expect(run('1.week').due_date).to be_within(60.seconds).of(1.week.from_now)
    end

    it 'creates the task with no due date when due_in is absent' do
      task = run(nil)

      expect(task).to be_present
      expect(task.due_date).to be_nil
    end

    it 'creates the task with no due date when due_in is an empty string' do
      task = run('')

      expect(task).to be_present
      expect(task.due_date).to be_nil
    end
  end

  describe 'an unreadable due_in' do
    ['abc', '1.destroy', 'tomorrow', '2026-99-99', 'd', '1.5.days'].each do |bad|
      it "refuses to create the task for #{bad.inspect}" do
        expect { run(bad) }.not_to change { pipeline_item.reload.tasks.count }.from(0)
      end
    end

    it 'never creates a task with a null due date when a due_in was given' do
      %w[abc 1.destroy 30m].each { |bad| run(bad) }

      expect(pipeline_item.reload.tasks.where(due_date: nil)).to be_empty
    end

    it 'logs the refusal with the offending value and the action' do
      allow(Rails.logger).to receive(:warn)

      run('abc')

      expect(Rails.logger).to have_received(:warn).with(/due_in "abc".*skipping create_pipeline_task/m)
    end
  end

  describe 'unit allowlist (arbitrary method dispatch)' do
    it 'never calls a method the rule names but the allowlist does not carry' do
      calls = []
      Integer.class_eval do
        define_method(:crm563_canary) do
          calls << :called
          1.day
        end
      end

      begin
        expect { run('1.crm563_canary') }.not_to change { pipeline_item.reload.tasks.count }.from(0)
        expect(calls).to be_empty
      ensure
        Integer.send(:remove_method, :crm563_canary)
      end
    end

    it 'does not blow up on "1.destroy" and creates nothing' do
      expect { run('1.destroy') }.not_to raise_error
      expect(pipeline_item.reload.tasks.count).to eq(0)
    end
  end

  describe 'execution timeline' do
    let(:rule) { rule_with('abc') }
    let(:recorder) do
      AutomationRules::RunRecorder.new(rule: rule, event_name: 'conversation_created', payload: {})
    end

    def run_with_recorder
      AutomationRules::ActionService.new(rule, nil, conversation, recorder: recorder).perform
      recorder.matched!
      recorder.persist!
      AutomationRuleRun.where(automation_rule_id: rule.id).last
    end

    it 'records the refusal as a warning step naming the reason' do
      run = run_with_recorder

      skipped = run.steps.find { |s| s['label'].to_s.include?('Skipped: create_pipeline_task') }
      expect(skipped).to be_present
      expect(skipped['level']).to eq('warn')
      expect(skipped.dig('data', 'reason')).to eq('invalid_due_in')
      expect(skipped.dig('data', 'due_in')).to eq('abc')
    end

    it 'downgrades the run status so it does not read as a clean match' do
      expect(run_with_recorder.status).to eq('skipped')
    end

    context 'when the due_in parses' do
      let(:rule) { rule_with('2d') }

      it 'keeps a clean match and adds no skip step' do
        run = run_with_recorder

        expect(run.steps.map { |s| s['label'] }).not_to include(a_string_matching(/Skipped/))
        expect(run.status).to eq('matched')
      end
    end
  end

  describe 'flow-canvas surface' do
    let(:flow_rule) { rule_with('2d') }
    let(:flow_service) { AutomationRules::FlowExecutionService.new(flow_rule, nil, conversation) }

    def flow_node(due_in)
      { 'type' => 'create-pipeline-task-node', 'id' => 'n1',
        'data' => { 'title' => 'Follow up', 'task_type' => 'call', 'priority' => 'medium', 'due_in' => due_in } }
    end

    it 'reads "2d" through a flow node' do
      flow_service.send(:execute_node_action, flow_node('2d'))

      expect(pipeline_item.reload.tasks.last.due_date).to be_within(60.seconds).of(2.days.from_now)
    end

    it 'refuses an unreadable due_in through a flow node' do
      expect { flow_service.send(:execute_node_action, flow_node('abc')) }
        .not_to change { pipeline_item.reload.tasks.count }.from(0)
    end
  end
end
