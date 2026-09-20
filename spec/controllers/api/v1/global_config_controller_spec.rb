require 'rails_helper'

RSpec.describe Api::V1::GlobalConfigController, type: :controller do
  before do
    # Stub with empty/default values to avoid DB dependency while preserving realistic behavior
    allow(GlobalConfigService).to receive(:load).and_wrap_original do |_method, key, default|
      default
    end
  end

  describe 'GET #show' do
    it 'returns public config without authentication' do
      get :show, format: :json
      expect(response).to have_http_status(:ok)
    end

    it 'exposes exactly the expected top-level keys (catches accidental additions/removals)' do
      get :show, format: :json
      json = JSON.parse(response.body)

      expected_keys = %w[
        fbAppId fbApiVersion wpAppId wpApiVersion wpWhatsappConfigId
        instagramAppId googleOAuthClientId azureAppId
        hasFacebookConfig hasWhatsappConfig hasInstagramConfig
        hasEvolutionConfig hasEvolutionGoConfig hasTwitterConfig
        openaiConfigured enableAccountSignup recaptchaSiteKey clarityProjectId
      ]

      # Exhaustive match — a drift that adds an unintended key (e.g. accidentally
      # exposing a secret) should fail this spec, not silently pass have_key loops.
      expect(json.keys).to match_array(expected_keys)
    end

    it 'includes recaptchaSiteKey in the response' do
      allow(GlobalConfigService).to receive(:load).with('RECAPTCHA_SITE_KEY', nil).and_return('6Lc_test_key')

      get :show, format: :json
      json = JSON.parse(response.body)
      expect(json['recaptchaSiteKey']).to eq('6Lc_test_key')
    end

    it 'includes clarityProjectId in the response' do
      allow(GlobalConfigService).to receive(:load).with('CLARITY_PROJECT_ID', nil).and_return('clarity_test_id')

      get :show, format: :json
      json = JSON.parse(response.body)
      expect(json['clarityProjectId']).to eq('clarity_test_id')
    end

    it 'returns nil for unconfigured recaptchaSiteKey' do
      get :show, format: :json
      json = JSON.parse(response.body)
      expect(json['recaptchaSiteKey']).to be_nil
    end

    it 'returns nil for unconfigured clarityProjectId' do
      get :show, format: :json
      json = JSON.parse(response.body)
      expect(json['clarityProjectId']).to be_nil
    end

    context 'integration hasXxxConfig booleans' do
      # Single source of truth: IntegrationRequirements reads every key via
      # GlobalConfigService.load(key, nil). Each case stubs the required keys
      # for one integration and asserts the matching boolean flips true.
      integrations = {
        'hasFacebookConfig' => %w[FB_APP_ID FB_APP_SECRET FB_VERIFY_TOKEN],
        'hasWhatsappConfig' => %w[WP_APP_ID WP_APP_SECRET WP_VERIFY_TOKEN WP_WHATSAPP_CONFIG_ID],
        'hasInstagramConfig' => %w[INSTAGRAM_APP_ID INSTAGRAM_APP_SECRET INSTAGRAM_VERIFY_TOKEN],
        'hasEvolutionConfig' => %w[EVOLUTION_API_URL EVOLUTION_ADMIN_SECRET],
        'hasEvolutionGoConfig' => %w[EVOLUTION_GO_API_URL EVOLUTION_GO_ADMIN_SECRET],
        'hasTwitterConfig' => %w[TWITTER_APP_ID TWITTER_CONSUMER_KEY TWITTER_CONSUMER_SECRET TWITTER_ENVIRONMENT]
      }

      integrations.each do |flag, required_keys|
        it "returns #{flag} true when every required key is populated" do
          required_keys.each do |key|
            allow(GlobalConfigService).to receive(:load).with(key, nil).and_return("value-for-#{key}")
          end

          get :show, format: :json
          json = JSON.parse(response.body)
          expect(json[flag]).to be true
        end

        it "returns #{flag} false when any required key is blank" do
          required_keys.each_with_index do |key, index|
            value = index.zero? ? '' : "value-for-#{key}"
            allow(GlobalConfigService).to receive(:load).with(key, nil).and_return(value)
          end

          get :show, format: :json
          json = JSON.parse(response.body)
          expect(json[flag]).to be false
        end

        it "returns #{flag} false when every required key is nil (default)" do
          get :show, format: :json
          json = JSON.parse(response.body)
          expect(json[flag]).to be false
        end
      end
    end

    context 'openaiConfigured' do
      it 'returns true when a model and a resolvable inbox-assist credential are set' do
        allow(GlobalConfigService).to receive(:load).with('OPENAI_MODEL', '').and_return('gpt-4')
        allow(Ai::CredentialResolver).to receive(:resolve_key).with(for_consumer: :inbox_assist).and_return('sk-test')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['openaiConfigured']).to be true
      end

      it 'returns false when no credential resolves for inbox_assist, even with a model set' do
        allow(GlobalConfigService).to receive(:load).with('OPENAI_MODEL', '').and_return('gpt-4')
        allow(Ai::CredentialResolver).to receive(:resolve_key).with(for_consumer: :inbox_assist).and_return(nil)

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['openaiConfigured']).to be false
      end

      it 'returns false when the model is blank, even with a resolvable credential' do
        allow(GlobalConfigService).to receive(:load).with('OPENAI_MODEL', '').and_return('')
        allow(Ai::CredentialResolver).to receive(:resolve_key).with(for_consumer: :inbox_assist).and_return('sk-test')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['openaiConfigured']).to be false
      end
    end

    context 'enableAccountSignup' do
      it 'returns true when configured' do
        allow(GlobalConfigService).to receive(:load).with('ENABLE_ACCOUNT_SIGNUP', 'false').and_return('true')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['enableAccountSignup']).to be true
      end

      it 'returns false by default' do
        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['enableAccountSignup']).to be false
      end
    end
  end
end
