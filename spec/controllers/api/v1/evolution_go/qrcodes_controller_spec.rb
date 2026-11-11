# frozen_string_literal: true

require 'rails_helper'

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

  # Regression coverage: /instance/connect kicks off pairing asynchronously on
  # the Evolution Go side, so /instance/qr called right after can 400 with
  # "no QR code available. Please wait a moment and try again" even though the
  # instance is about to succeed. Before this fix, #show surfaced that 400 as
  # "Erro ao gerar QR Code" on the very first attempt instead of retrying.
  describe '#fetch_qrcode_with_retry' do
    let(:controller_instance) { described_class.new }
    let(:http) { instance_double(Net::HTTP) }
    let(:request) { instance_double(Net::HTTP::Get) }
    let(:not_ready_response) do
      instance_double(Net::HTTPBadRequest,
                       code: '400',
                       body: '{"error":"no QR code available. Please wait a moment and try again"}')
    end

    before do
      allow(controller_instance).to receive(:sleep)
    end

    it 'returns immediately on the first successful response' do
      success_response = instance_double(Net::HTTPOK, code: '200', body: '{"data":{}}')
      allow(http).to receive(:request).with(request).and_return(success_response)

      result = controller_instance.send(:fetch_qrcode_with_retry, http, request)

      expect(result).to eq(success_response)
      expect(http).to have_received(:request).once
      expect(controller_instance).not_to have_received(:sleep)
    end

    it 'retries when the QR code is not ready yet, then returns the successful response' do
      success_response = instance_double(Net::HTTPOK, code: '200', body: '{"data":{}}')
      call_count = 0
      allow(http).to receive(:request).with(request) do
        call_count += 1
        call_count == 1 ? not_ready_response : success_response
      end

      result = controller_instance.send(:fetch_qrcode_with_retry, http, request)

      expect(result).to eq(success_response)
      expect(http).to have_received(:request).twice
      expect(controller_instance).to have_received(:sleep).with(described_class::QRCODE_NOT_READY_RETRY_DELAY).once
    end

    it 'gives up after the retry budget and returns the last not-ready response' do
      allow(http).to receive(:request).with(request).and_return(not_ready_response)

      result = controller_instance.send(:fetch_qrcode_with_retry, http, request)

      expect(result).to eq(not_ready_response)
      expect(http).to have_received(:request).exactly(described_class::QRCODE_NOT_READY_RETRY_COUNT + 1).times
    end

    it 'does not retry on a different error' do
      other_error_response = instance_double(Net::HTTPInternalServerError, code: '500', body: '{"error":"boom"}')
      allow(http).to receive(:request).with(request).and_return(other_error_response)

      result = controller_instance.send(:fetch_qrcode_with_retry, http, request)

      expect(result).to eq(other_error_response)
      expect(http).to have_received(:request).once
      expect(controller_instance).not_to have_received(:sleep)
    end
  end
end
