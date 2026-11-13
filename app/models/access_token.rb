# == Schema Information
#
# Table name: access_tokens
#
#  id         :uuid             not null, primary key
#  name       :string(255)      not null
#  owner_type :string
#  scopes     :string           not null
#  token      :string           (ignored; cleared by the auth HashAccessTokens migration)
#  token_digest :string
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  issued_id  :uuid
#  owner_id   :uuid
#
# Indexes
#
#  index_access_tokens_on_issued_id                (issued_id)
#  index_access_tokens_on_owner_type_and_owner_id  (owner_type,owner_id)
#  index_access_tokens_on_token                    (token) UNIQUE
#  index_access_tokens_on_token_digest             (token_digest) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (issued_id => users.id)
#
class AccessToken < ApplicationRecord
  # The auth owns this table and stores only the SHA-256 digest of the value.
  # The raw value exists in memory on the instance that generated it.
  self.ignored_columns += ['token']

  # Tokens with this scope are bounded by their owner alone (see the auth model).
  UNRESTRICTED_SCOPE = 'default'.freeze

  belongs_to :owner, polymorphic: true

  attr_reader :token

  validates :token_digest, presence: true, uniqueness: true

  # As before the digest: generated on create, after validation, so a token
  # created without a digest (AgentBot's after_create) is still not saved.
  before_create :generate_token

  def self.digest(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  def self.for_token(raw_token)
    return nil if raw_token.blank?

    find_by(token_digest: digest(raw_token)) ||
      # Written by an auth of the previous release during a rolling deploy.
      where(token_digest: nil).find_by('token = ?', raw_token.to_s)
  end

  def regenerate_token
    assign_token(SecureRandom.hex(32))
    save!
  end

  private

  def generate_token
    assign_token(SecureRandom.hex(32)) if token_digest.blank?
  end

  def assign_token(raw_token)
    @token = raw_token
    self.token_digest = self.class.digest(raw_token)
  end
end
