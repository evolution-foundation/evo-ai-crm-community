# frozen_string_literal: true

require 'rails_helper'

RSpec.describe EvoAuth::IdentityResolver do
  let(:user) { User.create!(name: 'Agent', email: "resolver-#{SecureRandom.hex(4)}@test.com") }
  let(:auth_service) { instance_double(EvoAuthService) }
  let(:user_data) { { 'user' => { 'id' => user.id, 'email' => user.email } } }
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }

  before { allow(Rails).to receive(:cache).and_return(cache) }

  def jwt_with_exp(exp)
    payload = Base64.urlsafe_encode64({ 'exp' => exp }.to_json, padding: false)
    "header.#{payload}.sig"
  end

  describe '.call' do
    it 'resolves the local user from the auth-service payload' do
      allow(auth_service).to receive(:validate_token).with(token: 'tok', token_type: 'bearer').and_return(user_data)

      identity = described_class.call(token: 'tok', auth_service: auth_service)

      expect(identity.user).to eq(user)
      expect(identity.user_data).to eq(user_data)
    end

    it 'serves repeated validations of the same token from the cache' do
      allow(auth_service).to receive(:validate_token).and_return(user_data)

      2.times { described_class.call(token: 'tok', auth_service: auth_service) }

      expect(auth_service).to have_received(:validate_token).once
    end

    it 'keys the cache by token type as well' do
      allow(auth_service).to receive(:validate_token).and_return(user_data)

      described_class.call(token: 'tok', token_type: 'bearer', auth_service: auth_service)
      described_class.call(token: 'tok', token_type: 'api_access_token', auth_service: auth_service)

      expect(auth_service).to have_received(:validate_token).twice
    end

    it 'bounds the cache TTL by the JWT exp' do
      token = jwt_with_exp(5.seconds.from_now.to_i)
      allow(auth_service).to receive(:validate_token).and_return(user_data)
      allow(cache).to receive(:write).and_call_original

      described_class.call(token: token, auth_service: auth_service)

      expect(cache).to have_received(:write).with(anything, user_data, expires_in: satisfy { |ttl| ttl.positive? && ttl <= 5.seconds })
    end

    it 'does not cache an already expired JWT' do
      token = jwt_with_exp(5.seconds.ago.to_i)
      allow(auth_service).to receive(:validate_token).and_return(user_data)
      allow(cache).to receive(:write).and_call_original

      described_class.call(token: token, auth_service: auth_service)

      expect(cache).not_to have_received(:write)
    end

    it 'raises ValidationError when the user does not exist locally' do
      allow(auth_service).to receive(:validate_token).and_return({ 'user' => { 'id' => SecureRandom.uuid, 'email' => 'ghost@test.com' } })

      expect { described_class.call(token: 'tok', auth_service: auth_service) }
        .to raise_error(EvoAuthService::ValidationError, /not found locally/)
    end

    it 'raises ValidationError on a blank token without calling the auth service' do
      allow(auth_service).to receive(:validate_token)

      expect { described_class.call(token: '', auth_service: auth_service) }.to raise_error(EvoAuthService::ValidationError)
      expect(auth_service).not_to have_received(:validate_token)
    end

    it 'raises ValidationError on an unsupported token type' do
      expect { described_class.call(token: 'tok', token_type: 'cookie', auth_service: auth_service) }
        .to raise_error(EvoAuthService::ValidationError, /token type/)
    end

    it 'propagates AuthenticationError when the auth service is unreachable' do
      allow(auth_service).to receive(:validate_token).and_raise(EvoAuthService::AuthenticationError, 'down')

      expect { described_class.call(token: 'tok', auth_service: auth_service) }.to raise_error(EvoAuthService::AuthenticationError)
    end
  end
end
