# frozen_string_literal: true

require 'rails_helper'

# CRM-563: the automation screen advertises "2d, 1w" for the create_pipeline_task due
# date (automation.json:create_pipeline_task_due_in, all 7 locales), and the parser
# understood neither — the task was created with due_date nil, no error, no log. The
# parser lives in the shared PipelineActionHandlers module, so it covers both executor
# surfaces (modal-style ActionService and flow-canvas FlowExecutionService) at once.
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

  # PipelineTask has `created_by_id NOT NULL`; production reads it via
  # `User.where(type: 'SuperAdmin').first&.id` and the Community fork removed the
  # SuperAdmin class (EVO-659), so the STI lookup throws unless it is stubbed.
  let(:created_by_user) { User.create!(name: 'CreatedBy', email: "cb-#{SecureRandom.hex(4)}@test.com") }

  before do
    allow(User).to receive(:where).and_call_original
    allow(User).to receive(:where).with(type: 'SuperAdmin').and_return(double(first: created_by_user))
  end

  after { Current.reset }

  def rule_with(due_in)
    # task_type/priority are passed explicitly by the handler, so a nil overrides the
    # column default and the record fails validation — the rule always carries them.
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

  # The bug as reported: the two examples printed on screen. With the old parser both
  # fall through split('.') and produce due_date nil.
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

    # "m" reads as minutes to one operator and months to the next; guessing either one
    # would silently schedule the other's task. It is refused instead of guessed.
    it 'refuses the ambiguous bare "m" instead of guessing minutes or months' do
      expect { run('30m') }.not_to(change { pipeline_item.reload.tasks.count })
    end
  end

  # Rules written before CRM-563 use these two, and they must keep working.
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

  # The whole point of the card: a due_in the parser cannot read must not turn into a
  # task that looks scheduled and never comes due.
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

  # `value.to_i.send(unit)` called whatever method the rule's JSON named, so a due_in of
  # "1.destroy" reached `1.destroy`. The allowlist is what stops user config from
  # dispatching arbitrary methods on Integer.
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

  # The operator reads the rule's execution timeline, not the Rails log — and the
  # listener records every action as success BEFORE running it, so a refusal that only
  # logged would still show up green.
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

  # The flow-canvas executor reaches the same handler through execute_node_action, with
  # its own node_data normalisation, so the parser needs coverage on that surface too.
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
