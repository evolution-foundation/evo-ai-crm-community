# == Schema Information
#
# Table name: access_tokens
#
#  id         :uuid             not null, primary key
#  name       :string(255)      not null
#  owner_type :string
#  scopes     :string           not null
#  token      :string           SHA-256 of the value
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
#
# Foreign Keys
#
#  fk_rails_...  (issued_id => users.id)
#
class AccessToken < ApplicationRecord
  # Tokens with this scope are bounded by their owner alone (see the auth model).
  UNRESTRICTED_SCOPE = 'default'.freeze

  belongs_to :owner, polymorphic: true

  validates :token, presence: true, uniqueness: true

  before_create :generate_token

  def self.digest(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  # The auth stores the SHA-256 of the value; a token stored before that still
  # holds the value (the auth hashes it on its next use).
  def self.for_token(raw_token)
    return nil if raw_token.blank?

    find_by(token: digest(raw_token)) || find_by(token: raw_token.to_s)
  end

  # The value on the instance that generated it; the stored hash otherwise.
  def token
    @raw_token || super
  end

  def regenerate_token
    assign_token(SecureRandom.hex(32))
    save!
  end

  private

  def generate_token
    assign_token(SecureRandom.hex(32))
  end

  def assign_token(raw_token)
    @raw_token = raw_token
    self[:token] = self.class.digest(raw_token)
  end
end
