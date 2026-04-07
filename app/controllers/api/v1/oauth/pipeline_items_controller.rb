# Herda diretamente do controller de accounts
class Api::V1::Oauth::PipelineItemsController < Api::V1::PipelineItemsController
  include Events::Types
  # Remove parent controller middlewares for OAuth
  skip_before_action :authenticate_request!

  skip_before_action :set_pipeline
  skip_before_action :set_pipeline_item
  skip_before_action :ensure_authorized_user

  # Aplica middleware OAuth
  include Doorkeeper::Rails::Helpers
  include OauthAccountHelper
  before_action :ensure_oauth_authentication!
  before_action :set_pipeline
  before_action :set_pipeline_item, only: [:update, :destroy, :move_to_stage, :update_conversation, :update_custom_fields]
  before_action :ensure_authorized_user

  # Override move_to_stage to handle parameter differences
  def move_to_stage
    begin
      # Handle both new_stage_id and pipeline_stage_id parameters
      stage_id = params[:new_stage_id] || params[:pipeline_stage_id]
      new_stage = @pipeline.pipeline_stages.find(stage_id)
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Stage not found in this pipeline' }, status: :not_found
      return
    end

    notes = params[:notes]

    if @pipeline_item.move_to_stage(new_stage, Current.user)
      # Add notes to the latest movement if provided
      if notes.present?
        latest_movement = @pipeline_item.stage_movements.last
        latest_movement.update!(notes: notes)
      end

      # Update conversation timestamp to ensure frontend gets the update (only for deals, not leads)
      if @pipeline_item.conversation.present?
        @pipeline_item.conversation.touch
        # Dispatch events to update frontend
        Rails.application.config.dispatcher.dispatch(CONVERSATION_UPDATED, Time.zone.now, conversation: @pipeline_item.conversation)
      end

      render json: {
        success: true,
        message: 'Conversation moved successfully',
        pipeline_item: @pipeline_item.push_event_data
      }
    else
      render json: { error: 'Failed to move conversation' }, status: :unprocessable_entity
    end
  end

  # Override bulk_move to handle parameter differences
  def bulk_move
    # Handle both parameter naming conventions
    conversation_ids = params[:pipeline_item_ids] || params[:conversation_ids] || []
    stage_id = params[:target_stage_id] || params[:new_stage_id]
    notes = params[:notes]

    begin
      new_stage = @pipeline.pipeline_stages.find(stage_id)
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Stage not found in this pipeline' }, status: :not_found
      return
    end

    moved_count = 0

    ActiveRecord::Base.transaction do
      conversation_ids.each do |conversation_id|
        pipeline_item = @pipeline.pipeline_items.find(conversation_id)
        next unless pipeline_item.move_to_stage(new_stage, Current.user)

        if notes.present?
          latest_movement = pipeline_item.stage_movements.last
          latest_movement.update!(notes: notes)
        end
        moved_count += 1
      end
    end

    render json: {
      success: true,
      moved_count: moved_count,
      message: "#{moved_count} conversations moved successfully"
    }
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def ensure_oauth_authentication!
    unless oauth_token_present?
      render_unauthorized('OAuth token required. This endpoint only accepts OAuth authentication.')
      return
    end

    # Verificar se o token é válido antes de chamar doorkeeper
    token = Doorkeeper::AccessToken.by_token(doorkeeper_token_value)
    unless token&.accessible?
      render_unauthorized('Invalid or expired OAuth token')
      return
    end

    # Verificar se tem escopo adequado
    unless token.acceptable?(['admin']) || token.acceptable?(['read']) || token.acceptable?(['pipelines:read'])
      render_unauthorized('Insufficient scope for this endpoint')
      return
    end

    # Token válido, continuar com autenticação
    @resource = User.find(token.resource_owner_id) if token.resource_owner_id
    Current.user = @resource if @resource
  end

  def doorkeeper_token_value
    request.headers['Authorization']&.gsub(/^Bearer\s+/, '')
  end

  # OAuth-aware version of parent controller methods
  def set_pipeline
    @pipeline = Pipeline.all.find(params[:pipeline_id])
    authorize @pipeline, :view?
  end

  def set_pipeline_item
    # For destroy and move_to_stage actions, try to find by conversation_id first, then by pipeline_item id
    if %w[destroy move_to_stage].include?(action_name)
      # First try to find by conversation display_id
      conversation = Conversation.all.find_by(display_id: params[:id])

      @pipeline_item = @pipeline.pipeline_items.find_by(conversation: conversation) if conversation

      # If not found, try by conversation id
      if @pipeline_item.nil?
        conversation = Conversation.all.find_by(id: params[:id])
        @pipeline_item = @pipeline.pipeline_items.find_by(conversation: conversation) if conversation
      end

      # If still not found, try by pipeline_item id as final fallback
      @pipeline_item = @pipeline.pipeline_items.find_by(id: params[:id]) if @pipeline_item.nil?

      if @pipeline_item.nil?
        render json: {
          error: "Conversation #{params[:id]} is not in pipeline #{@pipeline.name}"
        }, status: :not_found
        return
      end
    else
      @pipeline_item = @pipeline.pipeline_items.find(params[:id])
    end
  end

  def ensure_authorized_user
    authorize @pipeline, :view?
  end
end
