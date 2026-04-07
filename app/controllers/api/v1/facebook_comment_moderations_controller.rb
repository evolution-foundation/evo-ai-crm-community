# frozen_string_literal: true

module Api
  module V1
    class FacebookCommentModerationsController < Api::V1::BaseController
        before_action :fetch_moderation, only: [:show, :approve, :reject, :regenerate_response]
        before_action :fetch_conversation, only: [:index]

        require_permissions({
          index: 'conversations.read',
          show: 'conversations.read',
          approve: 'conversations.update',
          reject: 'conversations.update',
          regenerate_response: 'conversations.update'
        })

        def index
          @moderations = if @conversation.present?
            @conversation.facebook_comment_moderations
          else
            FacebookCommentModeration.all
          end

          @moderations = @moderations.where(status: params[:status]) if params[:status].present?
          @moderations = @moderations.where(moderation_type: params[:moderation_type]) if params[:moderation_type].present?
          @moderations = @moderations.pending if params[:pending_only] == 'true'

          @moderations = @moderations.recent.includes(:message, :conversation, :moderated_by)

          apply_pagination

          paginated_response(
            data: ::FacebookCommentModerationSerializer.serialize_collection(@moderations),
            collection: @moderations
          )
        end

        def show
          success_response(
            data: ::FacebookCommentModerationSerializer.serialize(@moderation),
            message: 'Moderation retrieved successfully'
          )
        end

        def approve
          if @moderation.approve!(Current.user)
            success_response(
              data: ::FacebookCommentModerationSerializer.serialize(@moderation),
              message: 'Moderation approved successfully'
            )
          else
            error_response(
              ApiErrorCodes::VALIDATION_ERROR,
              @moderation.errors.full_messages.join(', '),
              details: format_validation_errors(@moderation.errors),
              status: :unprocessable_entity
            )
          end
        end

        def reject
          # Get rejection_reason from params (can be nested in facebook_comment_moderation hash or top-level)
          reason = params.dig(:facebook_comment_moderation, :rejection_reason) || 
                   params[:rejection_reason] || 
                   params[:reason] || 
                   ''
          
          if @moderation.reject!(Current.user, reason.presence)
            success_response(
              data: ::FacebookCommentModerationSerializer.serialize(@moderation),
              message: 'Moderation rejected successfully'
            )
          else
            error_response(
              ApiErrorCodes::VALIDATION_ERROR,
              @moderation.errors.full_messages.join(', '),
              details: format_validation_errors(@moderation.errors),
              status: :unprocessable_entity
            )
          end
        end

        def regenerate_response
          unless @moderation.for_response_approval?
            return error_response(
              ApiErrorCodes::INVALID_PARAMETER,
              'Moderation is not for response approval',
              status: :bad_request
            )
          end

          # Queue job to regenerate response
          Facebook::Moderation::GenerateResponseJob.perform_later(
            @moderation.message_id,
            @moderation.conversation_id,
            @moderation.conversation.inbox.agent_bot_inbox&.agent_bot_for_conversation(@moderation.conversation)&.id
          )

          success_response(
            data: nil,
            message: 'Response regeneration queued successfully'
          )
        end

        private

        def fetch_moderation
          @moderation = FacebookCommentModeration.all.includes(:message, :conversation, :moderated_by).find(params[:id])
        end

        def fetch_conversation
          @conversation = Conversation.find(params[:conversation_id]) if params[:conversation_id].present?
        end
      end
    end
  end

