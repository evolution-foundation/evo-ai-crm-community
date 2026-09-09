# frozen_string_literal: true

require 'rails_helper'

# This fork defines no SuperAdmin STI class: super_admin is an auth-service role key
# resolved per request (Current.evo_role_key), never a users.type value.
RSpec.describe 'legacy SuperAdmin STI type' do # rubocop:disable RSpec/DescribeClass
  # update_all on purpose: assigning through the model needs the class to exist.
  def legacy_super_admin_row!
    user = User.create!(name: 'Legado', email: "legado-#{SecureRandom.hex(4)}@test.com")
    User.where(id: user.id).update_all(type: 'SuperAdmin') # rubocop:disable Rails/SkipsModelValidations
    user
  end

  # Instantiating such a row raises, so `User.where(type: 'SuperAdmin').first || fallback`
  # never reaches the fallback.
  describe 'the mechanism' do
    before { legacy_super_admin_row! }

    it 'raises when the lookup instantiates the row' do
      expect { User.where(type: 'SuperAdmin').first }.to raise_error(ActiveRecord::SubclassNotFound)
    end

    it 'does not raise when the row is only read, never instantiated' do
      expect { User.where(type: 'SuperAdmin').pluck(:id) }.not_to raise_error
      expect { User.exists?(type: 'SuperAdmin') }.not_to raise_error
    end
  end

  describe 'the idiom is gone from live code' do
    it 'no longer appears under app/ or lib/' do
      root = Rails.root
      offenders = Dir.glob(root.join('{app,lib}/**/*.rb')).select do |path|
        File.read(path).match?(/['"]SuperAdmin['"]/)
      end

      expect(offenders).to be_empty,
                           "SuperAdmin STI lookup is back in: #{offenders.map { |f| f.sub("#{root}/", '') }.join(', ')}"
    end
  end

  # Removing the lookups does not make legacy rows loadable; tolerance would be a data
  # migration normalising users.type, not defensive code.
  describe 'what this change deliberately does NOT fix' do
    it 'still cannot load a legacy row through a generic lookup' do
      legacy = legacy_super_admin_row!

      expect { User.find_by(id: legacy.id) }.to raise_error(ActiveRecord::SubclassNotFound)
    end
  end
end
