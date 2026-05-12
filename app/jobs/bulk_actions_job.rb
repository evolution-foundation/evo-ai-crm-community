class BulkActionsJob < ApplicationJob
  include DateRangeHelper

  queue_as :medium
  attr_accessor :records

  MODEL_TYPE = ['Conversation', 'Contact'].freeze

  def perform(account: nil, params:, user:)
    Current.user = user
    @params = params
    @records = records_to_updated(params[:ids])
    bulk_update
  ensure
    Current.reset
  end

  def bulk_update
    if @params[:type] == 'Contact'
      bulk_contact_update
      { success_ids: [], failed_ids: [] }
    else
      bulk_remove_labels
      bulk_conversation_update
    end
  end

  def bulk_contact_update
    action = @params[:fields]&.[](:action) || 'delete'

    case action
    when 'delete'
      bulk_delete_contacts
    end
  end

  def bulk_conversation_update
    params = available_params(@params)
    success_ids = []
    failed_ids = []

    records.each do |conversation|
      bulk_add_labels(conversation)
      bulk_snoozed_until(conversation)
      conversation.update!(params) if params
      success_ids << conversation.display_id
    rescue StandardError
      failed_ids << conversation.display_id
    end

    { success_ids: success_ids, failed_ids: failed_ids }
  end

  def bulk_remove_labels
    records.each do |conversation|
      remove_labels(conversation)
    end
  end

  def available_params(params)
    return unless params[:fields]

    params[:fields].delete_if { |key, value| value.nil? && key == 'status' }
  end

  def bulk_add_labels(conversation)
    conversation.add_labels(@params[:labels][:add]) if @params[:labels] && @params[:labels][:add]
  end

  def bulk_snoozed_until(conversation)
    conversation.snoozed_until = parse_date_time(@params[:snoozed_until].to_s) if @params[:snoozed_until]
  end

  def remove_labels(conversation)
    return unless @params[:labels] && @params[:labels][:remove]

    labels = conversation.label_list - @params[:labels][:remove]
    conversation.update!(label_list: labels)
  end

  def bulk_delete_contacts
    records.each do |contact|
      contact.destroy!
    end
  end

  def records_to_updated(ids)
    current_model = @params[:type].camelcase
    return unless MODEL_TYPE.include?(current_model)

    if current_model == 'Contact'
      current_model.constantize&.where(id: ids)
    else
      current_model.constantize&.where(display_id: ids)
    end
  end
end
