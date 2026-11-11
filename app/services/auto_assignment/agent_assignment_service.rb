class AutoAssignment::AgentAssignmentService
  # Allowed agent ids: array
  # This is the list of agents from which an agent can be assigned to this conversation
  # The round robin distributes among ALL selected collaborators (inbox members),
  # regardless of their online/offline status. Online status is intentionally ignored
  # to ensure every selected agent receives conversations even when marked as offline or unknown.
  pattr_initialize [:conversation!, :allowed_agent_ids!]

  def find_assignee
    # Distributes to all selected inbox members (allowed_agent_ids), ignoring online status
    round_robin_manage_service.available_agent(allowed_agent_ids: allowed_agent_ids&.map(&:to_s))
  end

  def perform
    new_assignee = find_assignee
    conversation.update!(assignee: new_assignee) if new_assignee
  end

  private

  def round_robin_manage_service
    @round_robin_manage_service ||= AutoAssignment::InboxRoundRobinService.new(inbox: conversation.inbox)
  end

  def round_robin_key
    format(::Redis::Alfred::ROUND_ROBIN_AGENTS, inbox_id: conversation.inbox_id)
  end
end
