class Api::V1::BulkActionsController < Api::V1::BaseController
  # Each contact action demands the permission of what it mutates.
  CONTACT_ACTION_PERMISSIONS = {
    'delete' => 'contacts.delete',
    'add_labels' => 'contacts.update',
    'remove_labels' => 'contacts.update',
    'update_custom_attributes' => 'contacts.update'
  }.freeze

  before_action :check_bulk_action_permission!
  before_action :type_matches?

  def create
    if type_matches?
      return invalid_contact_action if params[:type] == 'Contact' && contact_action_error

      result = ::BulkActionsJob.perform_now(
        user: current_user,
        params: permitted_params
      )

      success_response(
        data: result,
        message: 'Bulk action completed successfully',
        status: :created
      )
    else
      error_response(
        ApiErrorCodes::INVALID_PARAMETER,
        'Invalid type. Must be Conversation or Contact'
      )
    end
  end

  private

  # An unknown contact action is gated as an update, then refused with 422.
  def check_bulk_action_permission!
    permission_key = if params[:type] == 'Conversation'
                       'conversations.update'
                     else
                       CONTACT_ACTION_PERMISSIONS.fetch(contact_action, 'contacts.update')
                     end
    check_permission!(permission_key, :user)
  end

  def type_matches?
    ['Conversation', 'Contact'].include?(params[:type])
  end

  # Only an absent action means delete: a blank one is refused, never read as delete.
  def contact_action
    action = params.dig(:fields, :action)
    action.nil? ? 'delete' : action.to_s
  end

  def contact_action_error
    case contact_action
    when 'delete'
      nil
    when 'add_labels', 'remove_labels'
      'fields.labels must list at least one label' unless contact_labels_given?
    when 'update_custom_attributes'
      'fields.custom_attributes must be a non-empty object' if contact_custom_attributes.blank?
    else
      "Unknown contact action. Must be one of: #{CONTACT_ACTION_PERMISSIONS.keys.join(', ')}"
    end
  end

  # The permit below only keeps an array of scalars, so anything else would reach
  # the job as no labels at all.
  def contact_labels_given?
    labels = params.dig(:fields, :labels)
    labels.is_a?(Array) && labels.all?(String) && labels.compact_blank.any?
  end

  def contact_custom_attributes
    attributes = params.dig(:fields, :custom_attributes)
    attributes.to_unsafe_h if attributes.is_a?(ActionController::Parameters)
  end

  def invalid_contact_action
    error_response(ApiErrorCodes::INVALID_PARAMETER, contact_action_error, status: :unprocessable_entity)
  end

  # Labels and custom attributes in `fields` belong to the contact actions only:
  # a conversation bulk applies `fields` straight onto each conversation.
  def permitted_params
    fields = [:status, :assignee_id, :team_id, :action]
    fields += [{ labels: [] }, { custom_attributes: {} }] if params[:type] == 'Contact'
    params.permit(:type, :snoozed_until, ids: [], fields: fields, labels: [add: [], remove: []])
  end
end
