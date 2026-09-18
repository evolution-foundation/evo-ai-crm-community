module ArchivedInboxGuard
  private

  def reject_if_inbox_archived
    return unless archived_inbox_guard_target&.archived?

    render json: { error: I18n.t('messages.inbox_archived_rejects_new_content') }, status: :unprocessable_entity
  end
end
