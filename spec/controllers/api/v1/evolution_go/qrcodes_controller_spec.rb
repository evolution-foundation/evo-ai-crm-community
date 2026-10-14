# frozen_string_literal: true

require 'rails_helper'
require 'webmock/rspec'

# Pins that QrcodesController#set_instance_params resolves credentials through
# EvolutionGoConcern#evolution_go_credentials_for, so a refactor that drops the
# concern include or reverts to direct provider_config['api_url'] reads cannot
# silently regress legacy Evolution Go channels (the EVO-984 root cause).
RSpec.describe Api::V1::EvolutionGo::QrcodesController, type: :controller do
  describe '#set_instance_params' do
    let(:controller_instance) { described_class.new }
    let(:channel) do
      instance_double(
        Channel::Whatsapp,
        id: 'chan-uuid',
        provider_config: { 'api_url' => '', 'admin_token' => '', 'instance_token' => 'inst-tok',
                           'instance_uuid' => 'inst-uuid', 'instance_name' => 'inst-name' },
        inbox: instance_double(Inbox)
      )
    end

    before do
      controller_instance.params = ActionController::Parameters.new(id: 'inst-name')
      relation = double('relation')
      allow(Channel::Whatsapp).to receive(:joins).with(:inbox).and_return(relation)
      allow(relation).to receive(:where).and_return(relation)
      allow(relation).to receive(:first).and_return(channel)
    end

    it 'resolves api_url and admin_token from GlobalConfig when provider_config is empty' do
      allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://global.example.com')
      allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('global-secret')

      controller_instance.send(:set_instance_params)

      expect(controller_instance.instance_variable_get(:@api_url)).to eq('http://global.example.com')
      expect(controller_instance.instance_variable_get(:@instance_token)).to eq('inst-tok')
      expect(controller_instance.instance_variable_get(:@instance_uuid)).to eq('inst-uuid')
      expect(controller_instance.instance_variable_get(:@instance_name)).to eq('inst-name')
    end
  end

  # POST /qrcodes (refresh) é uma rota plana — não recebe :id. Antes do fix,
  # #create lia auth_params[:api_url] direto e respondia 400 quando o frontend
  # mandava só instance_uuid (canal legado pré-EVO-984), repetindo o sintoma da
  # issue. Estes testes pinam que o método agora resolve credenciais via canal.
  describe '#create credential resolution' do
    let(:controller_instance) { described_class.new }
    let(:channel) do
      instance_double(
        Channel::Whatsapp,
        id: 'chan-uuid',
        provider_config: { 'api_url' => '', 'instance_token' => 'inst-tok',
                           'instance_uuid' => 'inst-uuid', 'instance_name' => 'inst-name' },
        inbox: instance_double(Inbox)
      )
    end

    before do
      relation = double('relation')
      allow(Channel::Whatsapp).to receive(:joins).with(:inbox).and_return(relation)
      allow(relation).to receive(:where).and_return(relation)
      allow(relation).to receive(:first).and_return(channel)
    end

    it 'falls back to channel + GlobalConfig when payload has only instance_uuid' do
      controller_instance.params = ActionController::Parameters.new(qrcode: { instance_uuid: 'inst-uuid' })
      allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_API_URL', '').and_return('http://global.example.com')
      allow(GlobalConfigService).to receive(:load).with('EVOLUTION_GO_ADMIN_SECRET', '').and_return('global-secret')
      allow(controller_instance).to receive(:get_qrcode_go).with('http://global.example.com', 'inst-tok').and_return(base64: 'x', code: 'y', connected: false)

      expect(controller_instance).to receive(:render).with(
        hash_including(json: hash_including(success: true))
      )

      controller_instance.create
    end

    it 'still 400s when channel lookup fails and payload is missing credentials' do
      relation = double('relation')
      allow(Channel::Whatsapp).to receive(:joins).with(:inbox).and_return(relation)
      allow(relation).to receive(:where).and_return(relation)
      allow(relation).to receive(:first).and_return(nil)
      allow(GlobalConfigService).to receive(:load).and_return('')

      controller_instance.params = ActionController::Parameters.new(qrcode: { instance_uuid: 'unknown-uuid' })

      expect(controller_instance).to receive(:render).with(
        hash_including(status: :bad_request)
      )

      controller_instance.create
    end
  end

  # O Evolution Go 0.7.2 passou a serializar o QR em minúsculo ("qrcode"/"code");
  # até a 0.7.1 os campos vinham como "Qrcode"/"Code". Só a grafia antiga era
  # lida, então com a 0.7.2 o frontend recebia base64 nil e mostrava erro ao
  # gerar o QR. Estes testes pinam as duas grafias.
  describe '#get_qrcode_go' do
    let(:controller_instance) { described_class.new }
    let(:qr_url) { 'http://evo.example.com/instance/qr' }

    it 'reads the lowercase fields returned by Evolution Go 0.7.2+' do
      stub_request(:get, qr_url).with(headers: { 'apikey' => 'inst-tok' }).to_return(
        status: 200,
        body: { data: { qrcode: 'data:image/png;base64,AAA', code: '2@abc' }, message: 'success' }.to_json
      )

      result = controller_instance.send(:get_qrcode_go, 'http://evo.example.com', 'inst-tok')

      expect(result).to eq(base64: 'data:image/png;base64,AAA', code: '2@abc', connected: false)
    end

    it 'still reads the capitalized fields returned up to Evolution Go 0.7.1' do
      stub_request(:get, qr_url).with(headers: { 'apikey' => 'inst-tok' }).to_return(
        status: 200,
        body: { data: { Qrcode: 'data:image/png;base64,BBB', Code: '2@def' }, message: 'success' }.to_json
      )

      result = controller_instance.send(:get_qrcode_go, 'http://evo.example.com', 'inst-tok')

      expect(result).to eq(base64: 'data:image/png;base64,BBB', code: '2@def', connected: false)
    end
  end
end
