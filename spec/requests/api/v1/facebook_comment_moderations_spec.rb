# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::FacebookCommentModerationsController', type: :request do
  let(:user) { User.create!(name: 'Test User', email: "fb-moderations-#{SecureRandom.hex(4)}@example.com") }
  let(:service_token) { 'spec-service-token' }
  let(:headers) do
    {
      'X-Service-Token' => service_token
    }
  end

  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(channel: channel, name: 'Test Inbox') }
  let(:contact) { Contact.create!(name: 'Test Contact', email: 'contact@example.com') }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: 'test_source_id') }
  let(:conversation) do
    Conversation.create!(
      inbox: inbox,
      contact: contact,
      contact_inbox: contact_inbox,
      status: :open
    )
  end
  let(:message) do
    Message.create!(
      inbox: inbox,
      conversation: conversation,
      content: 'Test message content',
      message_type: :incoming,
      sender: contact,
      source_id: 'fb_comment_123'
    )
  end

  before do
    ENV['EVOAI_CRM_API_TOKEN'] = service_token
    Current.user = user
  end

  after do
    ENV.delete('EVOAI_CRM_API_TOKEN')
    Current.reset
  end

  def json_response
    JSON.parse(response.body)
  end

  describe 'GET /api/v1/facebook_comment_moderations' do
    let!(:moderation1) do
      FacebookCommentModeration.create!(
        conversation: conversation,
        message: message,
        comment_id: 'fb_comment_123',
        moderation_type: 'explicit_words',
        status: 'pending',
        action_type: 'delete_comment'
      )
    end

    let!(:moderation2) do
      FacebookCommentModeration.create!(
        conversation: conversation,
        message: message,
        comment_id: 'fb_comment_456',
        moderation_type: 'offensive_sentiment',
        status: 'approved',
        action_type: 'delete_comment',
        moderated_by: user,
        moderated_at: Time.current
      )
    end

    let!(:moderation3) do
      FacebookCommentModeration.create!(
        conversation: conversation,
        message: message,
        comment_id: 'fb_comment_789',
        moderation_type: 'response_approval',
        status: 'pending',
        action_type: 'send_response',
        response_content: 'Generated response'
      )
    end

    context 'when listing all moderations' do
      it 'returns paginated moderations with correct structure' do
        get '/api/v1/facebook_comment_moderations', headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['success']).to be true
        expect(json['data']).to be_an(Array)
        expect(json['data'].length).to eq(3)
        expect(json['meta']).to have_key('pagination')
        expect(json['meta']['pagination']).to include(
          'page', 'page_size', 'total', 'total_pages', 'has_next_page', 'has_previous_page'
        )
      end

      it 'includes nested objects (message, conversation, moderated_by) in response' do
        get '/api/v1/facebook_comment_moderations', headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        first_moderation = json['data'].first
        expect(first_moderation).to have_key('message')
        expect(first_moderation['message']).to include('id', 'content', 'created_at')
        expect(first_moderation).to have_key('conversation')
        expect(first_moderation['conversation']).to include('id', 'display_id')
      end

      it 'includes moderated_by when present' do
        get '/api/v1/facebook_comment_moderations', headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        approved_moderation = json['data'].find { |m| m['status'] == 'approved' }
        expect(approved_moderation).to have_key('moderated_by')
        expect(approved_moderation['moderated_by']).to include('id', 'name', 'email')
      end
    end

    context 'when filtering by status' do
      it 'returns only pending moderations' do
        get '/api/v1/facebook_comment_moderations', params: { status: 'pending' }, headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['data'].length).to eq(2)
        json['data'].each do |moderation|
          expect(moderation['status']).to eq('pending')
        end
      end

      it 'returns only approved moderations' do
        get '/api/v1/facebook_comment_moderations', params: { status: 'approved' }, headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['data'].length).to eq(1)
        expect(json['data'].first['status']).to eq('approved')
      end
    end

    context 'when filtering by moderation_type' do
      it 'returns only explicit_words moderations' do
        get '/api/v1/facebook_comment_moderations', params: { moderation_type: 'explicit_words' }, headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['data'].length).to eq(1)
        expect(json['data'].first['moderation_type']).to eq('explicit_words')
      end
    end

    context 'when filtering by pending_only' do
      it 'returns only pending moderations when pending_only=true' do
        get '/api/v1/facebook_comment_moderations', params: { pending_only: 'true' }, headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['data'].length).to eq(2)
        json['data'].each do |moderation|
          expect(moderation['status']).to eq('pending')
        end
      end
    end

    context 'when filtering by conversation_id' do
      let(:other_conversation) do
        Conversation.create!(
          inbox: inbox,
          contact: contact,
          contact_inbox: contact_inbox,
          status: :open
        )
      end

      let!(:other_moderation) do
        FacebookCommentModeration.create!(
          conversation: other_conversation,
          message: message,
          comment_id: 'fb_comment_999',
          moderation_type: 'explicit_words',
          status: 'pending',
          action_type: 'delete_comment'
        )
      end

      it 'returns only moderations for the specified conversation' do
        get '/api/v1/facebook_comment_moderations', params: { conversation_id: conversation.id }, headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['data'].length).to eq(3)
        json['data'].each do |moderation|
          expect(moderation['conversation_id']).to eq(conversation.id.to_s)
        end
      end
    end

    context 'when paginating results' do
      before do
        25.times do |i|
          FacebookCommentModeration.create!(
            conversation: conversation,
            message: message,
            comment_id: "fb_comment_#{i}",
            moderation_type: 'explicit_words',
            status: 'pending',
            action_type: 'delete_comment'
          )
        end
      end

      it 'returns paginated results with correct metadata' do
        get '/api/v1/facebook_comment_moderations', params: { page: 1, pageSize: 10 }, headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['data'].length).to eq(10)
        expect(json['meta']['pagination']['page']).to eq(1)
        expect(json['meta']['pagination']['page_size']).to eq(10)
        expect(json['meta']['pagination']['total']).to eq(28)
        expect(json['meta']['pagination']['has_next_page']).to be true
      end

      it 'returns second page correctly' do
        get '/api/v1/facebook_comment_moderations', params: { page: 2, pageSize: 10 }, headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['data'].length).to eq(10)
        expect(json['meta']['pagination']['page']).to eq(2)
        expect(json['meta']['pagination']['has_previous_page']).to be true
      end
    end

    context 'when there are no moderations' do
      before do
        FacebookCommentModeration.destroy_all
      end

      it 'returns empty array with correct pagination metadata' do
        get '/api/v1/facebook_comment_moderations', headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['success']).to be true
        expect(json['data']).to eq([])
        expect(json['meta']['pagination']['total']).to eq(0)
        expect(json['meta']['pagination']['total_pages']).to eq(1)
        expect(json['meta']['pagination']['has_next_page']).to be false
        expect(json['meta']['pagination']['has_previous_page']).to be false
      end
    end

    context 'when ordering by most recent first' do
      let!(:old_moderation) do
        moderation = FacebookCommentModeration.create!(
          conversation: conversation,
          message: message,
          comment_id: 'fb_comment_old',
          moderation_type: 'explicit_words',
          status: 'pending',
          action_type: 'delete_comment'
        )
        moderation.update_column(:created_at, 2.days.ago)
        moderation
      end

      it 'returns moderations ordered by created_at desc' do
        get '/api/v1/facebook_comment_moderations', headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        created_dates = json['data'].map { |m| Time.parse(m['created_at']) }
        expect(created_dates).to eq(created_dates.sort.reverse)
      end
    end
  end

  describe 'GET /api/v1/facebook_comment_moderations/:id' do
    let!(:moderation) do
      FacebookCommentModeration.create!(
        conversation: conversation,
        message: message,
        comment_id: 'fb_comment_123',
        moderation_type: 'response_approval',
        status: 'pending',
        action_type: 'send_response',
        response_content: 'Generated response',
        sentiment_offensive: false,
        sentiment_confidence: 0.85,
        sentiment_reason: 'Positive sentiment detected'
      )
    end

    it 'returns single moderation with nested objects' do
      get "/api/v1/facebook_comment_moderations/#{moderation.id}", headers: headers

      expect(response).to have_http_status(:ok)
      json = json_response

      expect(json['success']).to be true
      expect(json['data']['id']).to eq(moderation.id.to_s)
      expect(json['data']).to have_key('message')
      expect(json['data']['message']).to include('id', 'content', 'created_at')
      expect(json['data']).to have_key('conversation')
      expect(json['data']['conversation']).to include('id', 'display_id')
      expect(json['data']['sentiment_offensive']).to be false
      expect(json['data']['sentiment_confidence']).to eq(0.85)
    end

    context 'when moderation includes moderated_by' do
      before do
        moderation.update!(moderated_by: user, moderated_at: Time.current)
      end

      it 'includes moderated_by object' do
        get "/api/v1/facebook_comment_moderations/#{moderation.id}", headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['data']).to have_key('moderated_by')
        expect(json['data']['moderated_by']).to include('id', 'name', 'email')
        expect(json['data']['moderated_by']['id']).to eq(user.id.to_s)
      end
    end

    context 'when moderation not found' do
      it 'returns 404' do
        get '/api/v1/facebook_comment_moderations/00000000-0000-0000-0000-000000000000', headers: headers

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe 'POST /api/v1/facebook_comment_moderations/:id/approve' do
    let!(:moderation) do
      FacebookCommentModeration.create!(
        conversation: conversation,
        message: message,
        comment_id: 'fb_comment_123',
        moderation_type: 'explicit_words',
        status: 'pending',
        action_type: 'delete_comment'
      )
    end

    it 'approves moderation successfully' do
      post "/api/v1/facebook_comment_moderations/#{moderation.id}/approve", headers: headers

      expect(response).to have_http_status(:ok)
      json = json_response

      expect(json['success']).to be true
      expect(json['data']['status']).to eq('approved')
      expect(json['data']['moderated_by_id']).to eq(user.id.to_s)
      expect(json['message']).to include('approved successfully')

      moderation.reload
      expect(moderation.status).to eq('approved')
      expect(moderation.moderated_by).to eq(user)
    end

    context 'when moderation is already approved' do
      before do
        moderation.update!(status: 'approved', moderated_by: user)
      end

      it 'returns validation error' do
        post "/api/v1/facebook_comment_moderations/#{moderation.id}/approve", headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        json = json_response

        expect(json['success']).to be false
        expect(json['error']).to be_present
      end
    end
  end

  describe 'POST /api/v1/facebook_comment_moderations/:id/reject' do
    let!(:moderation) do
      FacebookCommentModeration.create!(
        conversation: conversation,
        message: message,
        comment_id: 'fb_comment_123',
        moderation_type: 'explicit_words',
        status: 'pending',
        action_type: 'delete_comment'
      )
    end

    it 'rejects moderation with reason' do
      post "/api/v1/facebook_comment_moderations/#{moderation.id}/reject",
           params: { rejection_reason: 'Inappropriate content' },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      json = json_response

      expect(json['success']).to be true
      expect(json['data']['status']).to eq('rejected')
      expect(json['data']['rejection_reason']).to eq('Inappropriate content')
      expect(json['data']['moderated_by_id']).to eq(user.id.to_s)
      expect(json['message']).to include('rejected successfully')

      moderation.reload
      expect(moderation.status).to eq('rejected')
      expect(moderation.rejection_reason).to eq('Inappropriate content')
      expect(moderation.moderated_by).to eq(user)
    end

    it 'accepts rejection_reason from nested params' do
      post "/api/v1/facebook_comment_moderations/#{moderation.id}/reject",
           params: { facebook_comment_moderation: { rejection_reason: 'Nested reason' } },
           headers: headers,
           as: :json

      expect(response).to have_http_status(:ok)
      json = json_response

      expect(json['data']['rejection_reason']).to eq('Nested reason')
    end

    context 'when moderation is already rejected' do
      before do
        moderation.update!(status: 'rejected', moderated_by: user, rejection_reason: 'Already rejected')
      end

      it 'returns validation error' do
        post "/api/v1/facebook_comment_moderations/#{moderation.id}/reject",
             params: { rejection_reason: 'New reason' },
             headers: headers,
             as: :json

        expect(response).to have_http_status(:unprocessable_entity)
        json = json_response

        expect(json['success']).to be false
        expect(json['error']).to be_present
      end
    end
  end

  describe 'POST /api/v1/facebook_comment_moderations/:id/regenerate_response' do
    let!(:moderation) do
      FacebookCommentModeration.create!(
        conversation: conversation,
        message: message,
        comment_id: 'fb_comment_123',
        moderation_type: 'response_approval',
        status: 'pending',
        action_type: 'send_response',
        response_content: 'Original response'
      )
    end

    context 'when moderation is for response approval' do
      it 'queues response regeneration job' do
        post "/api/v1/facebook_comment_moderations/#{moderation.id}/regenerate_response", headers: headers

        expect(response).to have_http_status(:ok)
        json = json_response

        expect(json['success']).to be true
        expect(json['message']).to include('queued successfully')
      end
    end

    context 'when moderation is not for response approval' do
      before do
        moderation.update!(moderation_type: 'explicit_words', action_type: 'delete_comment')
      end

      it 'returns error' do
        post "/api/v1/facebook_comment_moderations/#{moderation.id}/regenerate_response", headers: headers

        expect(response).to have_http_status(:bad_request)
        json = json_response

        expect(json['success']).to be false
        expect(json['error']['message']).to include('not for response approval')
      end
    end
  end
end
