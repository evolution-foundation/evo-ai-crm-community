# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccessToken do
  let(:user) { User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: 'Owner') }

  def create_token
    described_class.create!(owner: user, name: 'tk', scopes: 'default')
  end

  it 'stores only the digest of the value it generates' do
    token = create_token

    expect(token.token_digest).to eq(Digest::SHA256.hexdigest(token.token))
    expect(described_class.connection.select_value(
             "SELECT token FROM access_tokens WHERE id = #{described_class.connection.quote(token.id)}"
           )).to be_nil
  end

  it 'finds a token by its raw value' do
    token = create_token

    expect(described_class.for_token(token.token)).to eq(token)
    expect(described_class.for_token('not-a-token')).to be_nil
    expect(described_class.for_token(nil)).to be_nil
  end
end
