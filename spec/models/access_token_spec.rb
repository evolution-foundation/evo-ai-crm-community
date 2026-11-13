# frozen_string_literal: true

require 'rails_helper'

RSpec.describe AccessToken do
  let(:user) { User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", name: 'Owner') }

  def create_token
    described_class.create!(owner: user, name: 'tk', scopes: 'default', token: 'placeholder')
  end

  it 'stores the hash of the value it generates, never the value' do
    token = create_token

    expect(token.token).to match(/\A\h{64}\z/)
    expect(described_class.connection.select_value(
             "SELECT token FROM access_tokens WHERE id = #{described_class.connection.quote(token.id)}"
           )).to eq(Digest::SHA256.hexdigest(token.token))
  end

  it 'finds a token by its raw value' do
    token = create_token

    expect(described_class.for_token(token.token)).to eq(token)
    expect(described_class.for_token('not-a-token')).to be_nil
    expect(described_class.for_token(nil)).to be_nil
  end

  it 'finds a token stored before hashing by its value' do
    raw = SecureRandom.hex(32)
    id = SecureRandom.uuid
    described_class.connection.execute(<<~SQL.squish)
      INSERT INTO access_tokens (id, name, owner_type, owner_id, scopes, token, created_at, updated_at)
      VALUES ('#{id}', 'legacy', 'User', '#{user.id}', 'default', '#{raw}', now(), now())
    SQL

    expect(described_class.for_token(raw)&.id).to eq(id)
  end
end
