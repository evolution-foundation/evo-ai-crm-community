module AutoAssignmentHandler
  extend ActiveSupport::Concern
  include Events::Types

  included do
    after_save :run_auto_assignment
  end

  private

  def run_auto_assignment
    # Round robin kicks in on conversation create & update
    # run it only when conversation status changes to open or pending
    return unless conversation_status_changed_to_open? || conversation_status_changed_to_pending?
    return unless should_run_auto_assignment?

    # Distributes among all selected collaborators (inbox members) regardless of online status.
    # member_ids_with_assignment_capacity returns ALL inbox members — no capacity or online filter.
    ::AutoAssignment::AgentAssignmentService.new(conversation: self, allowed_agent_ids: inbox.member_ids_with_assignment_capacity).perform
  end

  def should_run_auto_assignment?
    # Requires auto assignment to be enabled on the inbox (default: true)
    return false unless inbox.enable_auto_assignment?

    # Only auto-assign if conversation has no agent yet — avoids overwriting manual assignments
    assignee.blank?
  end
end
