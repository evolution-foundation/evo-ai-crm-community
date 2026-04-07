# == Schema Information
#
# Table name: runtime_configs
#
#  id         :bigint           not null, primary key
#  key        :string           not null
#  value      :text             default(""), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_runtime_configs_on_key  (key) UNIQUE
#
class RuntimeConfig < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :value, presence: true

  def self.get(key)
    find_by(key: key)&.value
  end

  def self.get_json(key)
    raw = get(key)
    raw ? JSON.parse(raw) : nil
  end

  def self.set(key, value)
    record = find_or_initialize_by(key: key)
    record.value = value.is_a?(String) ? value : value.to_json
    record.save!
  end

  def self.delete_key(key)
    find_by(key: key)&.destroy
  end

  def self.account
    get_json('account')
  end
end
