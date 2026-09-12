# frozen_string_literal: true

require 'rails_helper'

# CRM-606: the public CSAT page (`FRONTEND_URL/survey/responses/<conversation.uuid>`)
# rendered nothing because both actions were bodyless — `format: 'json'` + an action
# with no template falls through to ImplicitRender's `head :no_content`, so the page
# got a 204 and never learned what to ask about.
RSpec.describe 'Public CSAT Survey API', type: :request do
  include ActiveJob::TestHelper

  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'suporte', channel: channel, csat_config: { 'display_type' => 'star', 'message' => 'Como foi o atendimento?' }) }
  let(:contact) { Contact.create!(name: 'Ada Lovelace', email: "ada-#{SecureRandom.hex(4)}@test.com") }
  let(:contact_inbox) { ContactInbox.create!(inbox: inbox, contact: contact, source_id: SecureRandom.hex(4)) }
  let(:conversation) { Conversation.create!(inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  let!(:csat_message) do
    conversation.messages.create!(
      inbox: inbox,
      message_type: :template,
      content_type: :input_csat,
      content: 'Como foi o atendimento?',
      content_attributes: { display_type: 'star' }
    )
  end

  describe 'GET /public/api/v1/csat_survey/:id' do
    it 'answers 200 with the body the survey page renders from' do
      get "/public/api/v1/csat_survey/#{conversation.uuid}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['inbox_name']).to eq('suporte')
      expect(body['display_type']).to eq('star')
      expect(body['content']).to eq('Como foi o atendimento?')
      expect(body).to have_key('inbox_avatar_url')
    end

    # The page hides the rating widget whenever `csat_survey_response.rating` is
    # merely PRESENT — `rating: null` reads as "already answered" and would lock an
    # unanswered survey out of being answered.
    it 'answers a null csat_survey_response while the survey is unanswered' do
      get "/public/api/v1/csat_survey/#{conversation.uuid}"

      expect(JSON.parse(response.body)['csat_survey_response']).to be_nil
    end

    it 'answers the stored rating and feedback once the survey is answered' do
      CsatSurveyResponse.create!(
        message: csat_message, conversation: conversation, contact: contact,
        rating: 4, feedback_message: 'Rápido e educado'
      )

      get "/public/api/v1/csat_survey/#{conversation.uuid}"

      expect(JSON.parse(response.body)['csat_survey_response'])
        .to eq('rating' => 4, 'feedback_message' => 'Rápido e educado')
    end

    # `Message#content` appends the survey link, and Liquidable's before_create
    # renders that appended string into the column — so echoing the stored message
    # back would print the page's own URL inside the page.
    it 'answers the configured prompt without the survey link appended' do
      get "/public/api/v1/csat_survey/#{conversation.uuid}"

      body = JSON.parse(response.body)
      expect(body['content']).to eq('Como foi o atendimento?')
      expect(body['content']).not_to include('/survey/responses/')
    end

    # No server-side default, so the page can render its own in the READER's
    # language: this endpoint is anonymous and PublicController does not include
    # SwitchLocale, so an `I18n.t` here would resolve at I18n.default_locale and
    # serve one installation-wide language to every contact of every account. With
    # the key absent the page falls back to `survey.description`, which is where
    # that phrase has its single owner.
    it 'omits the prompt entirely when the inbox configures no message' do
      inbox.update!(csat_config: { 'display_type' => 'star' })

      get "/public/api/v1/csat_survey/#{conversation.uuid}"

      body = JSON.parse(response.body)
      expect(body).not_to have_key('content')
      expect(body['display_type']).to eq('star')
    end

    it 'falls back to the emoji display type when the message carries none' do
      csat_message.update!(content_attributes: {})

      get "/public/api/v1/csat_survey/#{conversation.uuid}"

      expect(JSON.parse(response.body)['display_type']).to eq('emoji')
    end
  end

  describe 'PUT /public/api/v1/csat_survey/:id' do
    let(:rating_payload) do
      { message: { submitted_values: { csat_survey_response: { rating: 5, feedback_message: 'Perfeito' } } } }
    end

    it 'answers 200 with a body and stores the submitted values on the message' do
      put "/public/api/v1/csat_survey/#{conversation.uuid}", params: rating_payload, as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to have_key('csat_survey_response')
      expect(csat_message.reload.content_attributes.dig('submitted_values', 'csat_survey_response', 'rating')).to eq(5)
    end

    # The acceptance criterion is that the rating lands on the RIGHT conversation,
    # and the message's content_attributes above is not where that is settled: the
    # `csat_survey_responses` row every report reads is written by
    # CsatSurveyListener, which runs inside EventDispatcherJob (AsyncDispatcher).
    # Query it straight after the PUT and it is still empty, so draining that job is
    # the only way to see the write. Same harness as
    # spec/listeners/automation_rule_listener_pipeline_stage_updated_e2e_spec.rb.
    context 'when the MESSAGE_UPDATED fan-out runs' do
      let(:other_contact) { Contact.create!(name: 'Grace Hopper', email: "grace-#{SecureRandom.hex(4)}@test.com") }
      let(:other_contact_inbox) { ContactInbox.create!(inbox: inbox, contact: other_contact, source_id: SecureRandom.hex(4)) }
      let(:other_conversation) { Conversation.create!(inbox: inbox, contact: other_contact, contact_inbox: other_contact_inbox) }
      let!(:other_csat_message) do
        other_conversation.messages.create!(
          inbox: inbox, message_type: :template, content_type: :input_csat,
          content: 'Como foi o atendimento?', content_attributes: { display_type: 'star' }
        )
      end

      it 'has recorded nothing at the moment the endpoint answers' do
        put "/public/api/v1/csat_survey/#{conversation.uuid}", params: rating_payload, as: :json

        expect(response).to have_http_status(:ok)
        expect(CsatSurveyResponse.where(message_id: csat_message.id)).to be_empty
      end

      it 'records the rating on the rated conversation, its contact and its message' do
        perform_enqueued_jobs(only: [EventDispatcherJob]) do
          put "/public/api/v1/csat_survey/#{conversation.uuid}", params: rating_payload, as: :json
        end

        recorded = CsatSurveyResponse.find_by!(message_id: csat_message.id)
        expect(recorded.rating).to eq(5)
        expect(recorded.feedback_message).to eq('Perfeito')
        expect(recorded.conversation_id).to eq(conversation.id)
        expect(recorded.contact_id).to eq(contact.id)
      end

      it 'leaves the other open survey in the same inbox unrated' do
        perform_enqueued_jobs(only: [EventDispatcherJob]) do
          put "/public/api/v1/csat_survey/#{conversation.uuid}", params: rating_payload, as: :json
        end

        expect(CsatSurveyResponse.where(conversation_id: other_conversation.id)).to be_empty
        expect(CsatSurveyResponse.where(message_id: other_csat_message.id)).to be_empty
        expect(CsatSurveyResponse.count).to eq(1)
      end
    end

    it 'refuses a survey older than 14 days with the error the page shows' do
      csat_message.update_column(:created_at, 20.days.ago)

      put "/public/api/v1/csat_survey/#{conversation.uuid}", params: rating_payload, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)['error']).to include('14 days')
    end
  end
end
