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

    it 'includes all expected top-level keys' do
      get :show, format: :json
      json = JSON.parse(response.body)

      expected_keys = %w[
        fbAppId fbApiVersion wpAppId wpApiVersion wpWhatsappConfigId
        instagramAppId googleOAuthClientId azureAppId
        hasEvolutionConfig hasEvolutionGoConfig openaiConfigured
        enableAccountSignup recaptchaSiteKey clarityProjectId whitelabel
      ]

      expected_keys.each do |key|
        expect(json).to have_key(key), "Expected response to include key '#{key}'"
      end
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

    context 'boolean flags' do
      it 'returns hasEvolutionConfig true when API URL and secret are configured' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_URL', '').and_return('https://evo.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_ADMIN_SECRET', '').and_return('secret123')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['hasEvolutionConfig']).to be true
      end

      it 'returns hasEvolutionConfig false when API URL or secret is missing' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_API_URL', '').and_return('https://evo.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_ADMIN_SECRET', '').and_return('')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['hasEvolutionConfig']).to be false
      end

      it 'returns hasEvolutionGoConfig true when API URL and secret are configured' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('https://evogo.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('secret456')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['hasEvolutionGoConfig']).to be true
      end

      it 'returns openaiConfigured true when URL, key and model are all set' do
        allow(GlobalConfigService).to receive(:load).with('OPENAI_API_URL', '').and_return('https://api.openai.com')
        allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', '').and_return('sk-test')
        allow(GlobalConfigService).to receive(:load).with('OPENAI_MODEL', '').and_return('gpt-4')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['openaiConfigured']).to be true
      end

      it 'returns openaiConfigured false when any OpenAI field is missing' do
        allow(GlobalConfigService).to receive(:load).with('OPENAI_API_URL', '').and_return('https://api.openai.com')
        allow(GlobalConfigService).to receive(:load).with('OPENAI_API_SECRET', '').and_return('')
        allow(GlobalConfigService).to receive(:load).with('OPENAI_MODEL', '').and_return('gpt-4')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['openaiConfigured']).to be false
      end

      it 'returns hasEvolutionGoConfig false when API URL or secret is missing' do
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('https://evogo.example.com')
        allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['hasEvolutionGoConfig']).to be false
      end

      it 'returns enableAccountSignup true when configured' do
        allow(GlobalConfigService).to receive(:load).with('ENABLE_ACCOUNT_SIGNUP', 'false').and_return('true')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['enableAccountSignup']).to be true
      end

      it 'returns enableAccountSignup false by default' do
        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['enableAccountSignup']).to be false
      end
    end

    context 'whitelabel config' do
      it 'returns whitelabel disabled when WHITELABEL_ENABLED is false' do
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_ENABLED', 'false').and_return('false')

        get :show, format: :json
        json = JSON.parse(response.body)
        expect(json['whitelabel']).to eq({ 'enabled' => false })
      end

      it 'returns full whitelabel object when enabled' do
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_ENABLED', 'false').and_return('true')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_LOGO_LIGHT', '/brand-assets/logo.svg').and_return('/custom/logo.svg')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_LOGO_DARK', '/brand-assets/logo_dark.svg').and_return('/custom/logo_dark.svg')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_FAVICON', nil).and_return('/custom/favicon.ico')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_COMPANY_NAME', nil).and_return('Acme Corp')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_SYSTEM_NAME', nil).and_return('Acme Platform')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_TERMS_OF_SERVICE_URL', nil).and_return('https://acme.com/tos')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_PRIVACY_POLICY_URL', nil).and_return('https://acme.com/privacy')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_PRIMARY_COLOR_LIGHT', '#00d4aa').and_return('#ff0000')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_PRIMARY_FOREGROUND_LIGHT', '#ffffff').and_return('#000000')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_PRIMARY_COLOR_DARK', '#00ffcc').and_return('#00ff00')
        allow(GlobalConfigService).to receive(:load).with('WHITELABEL_PRIMARY_FOREGROUND_DARK', '#000000').and_return('#ffffff')

        get :show, format: :json
        json = JSON.parse(response.body)
        wl = json['whitelabel']

        expect(wl['enabled']).to be true
        expect(wl['logo']['light']).to eq('/custom/logo.svg')
        expect(wl['logo']['dark']).to eq('/custom/logo_dark.svg')
        expect(wl['favicon']).to eq('/custom/favicon.ico')
        expect(wl['companyName']).to eq('Acme Corp')
        expect(wl['systemName']).to eq('Acme Platform')
        expect(wl['termsOfServiceUrl']).to eq('https://acme.com/tos')
        expect(wl['privacyPolicyUrl']).to eq('https://acme.com/privacy')
        expect(wl['colors']['light']['primary']).to eq('#ff0000')
        expect(wl['colors']['dark']['primary']).to eq('#00ff00')
      end
    end
  end
end
