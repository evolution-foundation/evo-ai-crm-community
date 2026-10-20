# frozen_string_literal: true

class Api::V1::DealsController < Api::V1::BaseController
  before_action :set_pipeline, only: [:index, :create]
  before_action :set_deal, only: [:show, :update, :destroy]
  before_action :authorize_read, only: [:index, :show]
  before_action :authorize_write, only: [:create, :update, :destroy]

  def index
    deals = deal_scope.where(pipeline: @pipeline).order(updated_at: :desc)
    success_response(data: DealSerializer.serialize_collection(deals, include_details: false), message: 'Deals retrieved successfully')
  end

  def show
    success_response(data: DealSerializer.serialize(@deal), message: 'Deal retrieved successfully')
  end

  def create
    stage = @pipeline.pipeline_stages.find(deal_params[:pipeline_stage_id].presence || @pipeline.pipeline_stages.order(:position).pick(:id))
    attributes = deal_params.except(:pipeline_stage_id, :contact_ids, :conversation_ids, :labels)
    PipelineItem.transaction do
      @deal = @pipeline.pipeline_items.new(attributes.merge(pipeline_stage: stage, assigned_by: Current.user))
      @deal.owner ||= Current.user
      @deal.save!
      attach_initial_associations
      @deal.update_deal_labels!(deal_params[:labels]) if deal_params.key?(:labels)
    end
    success_response(
      data: DealSerializer.serialize(reload_deal), message: 'Deal created successfully', status: :created
    )
  rescue ActiveRecord::RecordInvalid => e
    validation_error(e)
  end

  def update
    attributes = deal_params.except(:contact_ids, :conversation_ids, :labels)
    PipelineItem.transaction do
      if attributes[:pipeline_stage_id].present?
        stage = @deal.pipeline.pipeline_stages.find(attributes.delete(:pipeline_stage_id))
        @deal.move_to_stage(stage, Current.user)
      end
      @deal.update!(attributes) unless attributes.empty?
      @deal.update_deal_labels!(deal_params[:labels]) if deal_params.key?(:labels)
    end
    success_response(data: DealSerializer.serialize(reload_deal), message: 'Deal updated successfully')
  rescue ActiveRecord::RecordInvalid => e
    validation_error(e)
  end

  def destroy
    @deal.destroy!
    success_response(data: { id: @deal.id, deal_id: @deal.id }, message: 'Deal removed successfully')
  end

  private

  def set_pipeline
    @pipeline = Pipeline.find(params[:pipeline_id])
  end

  def set_deal
    @deal = deal_scope.find(params[:id])
    @pipeline = @deal.pipeline
  end

  def deal_scope
    PipelineItem.includes(
      :pipeline, :pipeline_stage, :conversation, :labels,
      :deal_contacts, :deal_conversations, :tasks, :scheduled_actions, :stage_movements,
      :deal_history_events, attachments: { file_attachment: :blob },
      owner: { avatar_attachment: :blob },
      company: [:labels, { avatar_attachment: :blob }],
      contact: [:labels, { avatar_attachment: :blob }],
      primary_contact: [:labels, { avatar_attachment: :blob }],
      contacts: [:labels, { avatar_attachment: :blob }],
      conversations: [:inbox, { contact: [:labels, { avatar_attachment: :blob }], messages: [:attachments, :sender] }],
      deal_history_events: :actor,
      stage_movements: [:from_stage, :to_stage, :moved_by]
    )
  end

  def reload_deal
    deal_scope.find(@deal.id)
  end

  def authorize_read
    authorize @pipeline, :view? unless service_authenticated?
  end

  def authorize_write
    authorize @pipeline, :update? unless service_authenticated?
  end

  def deal_params
    source = params[:deal].presence || params
    source.permit(:title, :value, :currency, :notes, :owner_id, :company_id, :primary_contact_id,
                  :pipeline_stage_id, contact_ids: [], conversation_ids: [], labels: [], custom_fields: {})
  end

  def attach_initial_associations
    Array(deal_params[:contact_ids]).each { |id| @deal.attach_contact!(Contact.find(id)) }
    Array(deal_params[:conversation_ids]).each { |id| @deal.attach_conversation!(Conversation.find(id)) }
  end

  def validation_error(error)
    error_response(
      ApiErrorCodes::VALIDATION_ERROR,
      error.record.errors.full_messages.join(', '),
      details: error.record.errors.as_json,
      status: :unprocessable_entity
    )
  end
end
