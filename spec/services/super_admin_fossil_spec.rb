# frozen_string_literal: true

require 'rails_helper'

# CRM-578: `User.where(type: 'SuperAdmin')` appeared in six places in live code, and it is
# a fossil of the upstream project — this fork defines no `SuperAdmin` class anywhere.
#
# The modern concept has a different shape entirely: `super_admin` is an auth-service ROLE
# KEY, resolved per request into `Current.evo_role_key` (see
# app/models/concerns/user_attribute_helpers.rb#administrator? and the auth migration
# PromoteFirstUserToSuperAdmin, which creates a role, not a user type). Nothing in this
# ecosystem ever writes `users.type = 'SuperAdmin'`, which is why the query returned an
# empty set in every installation measured.
#
# The lookup therefore contributed nothing — but it was not harmless, and that is what
# these examples pin.
RSpec.describe 'the SuperAdmin STI fossil (CRM-578)' do
  let(:account_user) { User.create!(name: 'Agente', email: "agente-#{SecureRandom.hex(4)}@test.com") }

  # A row typed as an STI subclass that does not exist. Written with update_all on purpose:
  # assigning it through the model would need the class to be defined, and its absence is
  # exactly what is under test.
  def legacy_super_admin_row!
    user = User.create!(name: 'Legado', email: "legado-#{SecureRandom.hex(4)}@test.com")
    User.where(id: user.id).update_all(type: 'SuperAdmin') # rubocop:disable Rails/SkipsModelValidations
    user
  end

  # Why the idiom is banned rather than merely useless. Reading such a row instantiates it,
  # and instantiation is what blows up — before any `|| User.first` fallback can run, since
  # the exception happens while the left-hand side is being evaluated.
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

  # Note on coverage, stated rather than hidden: the two `.pluck` call sites (mentions and
  # assignable agents) cannot be exercised behaviourally in this fork right now. The mention
  # pipeline is inert for an unrelated reason — Messages::MentionService extracts ids with
  # %r{\(mention://(user|team)/(\d+)/} while this fork keys users by UUID, so no mention
  # ever validates. Writing an example around it would pin a broken pipeline instead of this
  # change. Raised separately; here the removal is covered by the mechanism and the guard
  # below, since the ids the fossil contributed were provably always an empty list.

  # The two `.first` call sites that pick a message sender live inside a WhatsApp job and a
  # Facebook moderation executor; standing either fixture up would test their surroundings,
  # not this change. What is worth pinning is that the banned idiom does not come back —
  # the fossil survived this long precisely because nothing watched for it.
  describe 'the idiom is gone from live code' do
    it 'no longer appears under app/ or lib/' do
      root = Rails.root
      offenders = Dir.glob(root.join('{app,lib}/**/*.rb')).select do |path|
        File.read(path).include?("where(type: 'SuperAdmin')")
      end

      # pipeline_action_handlers.rb is fixed by CRM-576 in its own pull request; until that
      # one lands this file is the single permitted exception.
      offenders -= [root.join('app/services/automation_rules/pipeline_action_handlers.rb').to_s]

      expect(offenders).to be_empty,
                           "SuperAdmin STI lookup is back in: #{offenders.map { |f| f.sub("#{root}/", '') }.join(', ')}"
    end
  end

  # The boundary of this change, pinned so nobody reads more into it than it does.
  #
  # Removing the six lookups does NOT make the application tolerate a row typed with a
  # class that does not exist. ANY generic load of that user raises — the example below
  # uses the presence tracker, which auto-assignment calls on every conversation, and
  # `User.find_by` is all it takes.
  #
  # So "be resilient to legacy SuperAdmin rows" is not a code change scattered across call
  # sites; it would be a data migration normalising `users.type`. No installation measured
  # carries such a row (zero in the SaaS database, zero in community), which is why this
  # card removes dead weight instead of writing defensive code for a row nobody has.
  describe 'what this change deliberately does NOT fix' do
    it 'still cannot load a legacy row through a generic lookup' do
      legacy = legacy_super_admin_row!

      expect { User.find_by(id: legacy.id) }.to raise_error(ActiveRecord::SubclassNotFound)
    end
  end
end
