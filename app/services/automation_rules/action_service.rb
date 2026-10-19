class AutomationRules::ActionService < ActionService
  # Pipeline + message action implementations live in shared modules so the
  # flow-canvas executor (FlowExecutionService) can reuse the same code
  # without duplication. The conversation-bound actions (assign/label/status/
  # message/attachment/email/webhook) come from ConversationActionHandlers via
  # the base ActionService — see app/services/automation_rules/README.md.
  include AutomationRules::PipelineActionHandlers
  include AutomationRules::MessageActionHandlers

  def initialize(rule, _account = nil, conversation = nil)
    super(conversation)
    @rule = rule
    Current.executed_by = rule
  end

  def perform
    return if Instagram::AmhSafety.blocked_inbox?(@conversation&.inbox)

    @rule.actions.each do |action|
      @conversation.reload
      action = action.with_indifferent_access
      begin
        Rails.logger.info "Automation Rule #{@rule.id}: Executing action #{action[:action_name]} with params #{action[:action_params]}"
        send(action[:action_name], action[:action_params])
      rescue StandardError => e
        Rails.logger.error "Automation Rule #{@rule.id}: Error executing action #{action[:action_name]}: #{e.message}"
        EvolutionExceptionTracker.new(e).capture_exception
      end
    end
  ensure
    Current.reset
  end
end
