# frozen_string_literal: true

require 'rails_helper'

# CRM-579 — the conversation mention was retired, not disabled.
#
# Two jobs here. The first is the removal itself: a partial revert (a leftover
# listener method, a constant the grep missed) is the failure mode of a feature
# deleted across 31 files. The second is the claim the retirement rests on —
# `NotificationSetting` derives its FlagShihTzu flags from the VALUES of
# NOTIFICATION_TYPES, so those values are bit POSITIONS. Dropping key 4 leaves
# bit 4 orphaned and inert; renumbering the survivors would silently move every
# notification preference already saved. The second block is what goes red if
# someone later "tidies up" the remaining numbers.

# `type => the flags integer a user with ONLY that type enabled carries`.
# Bit position N is worth 2**(N-1); these are the numbers sitting in
# notification_settings.email_flags / push_flags in every live database.
SAVED_BIT_VALUES = {
  conversation_creation: 1,
  conversation_assignment: 2,
  assigned_conversation_new_message: 4,
  participating_conversation_new_message: 16,
  pipeline_task_assigned: 524_288,
  pipeline_task_due_soon: 1_048_576,
  pipeline_task_overdue: 2_097_152,
  pipeline_task_completed: 4_194_304
}.freeze

RSpec.describe 'conversation_mention retirement (CRM-579)' do # rubocop:disable RSpec/DescribeClass
  describe 'nothing of the feature is left' do
    it 'drops the notification type' do
      expect(Notification::NOTIFICATION_TYPES).not_to have_key(:conversation_mention)
    end

    it 'drops the mentions table' do
      expect(ActiveRecord::Base.connection.table_exists?('mentions')).to be(false)
    end

    it 'drops the Mention model and its two writers' do
      expect(Object.const_defined?(:Mention, false)).to be(false)
      expect(Messages.const_defined?(:MentionService, false)).to be(false)
      expect(Conversations.const_defined?(:UserMentionJob, false)).to be(false)
    end

    it 'drops the mention regex and the event it dispatched' do
      expect(RegexHelper.const_defined?(:MENTION_REGEX, false)).to be(false)
      expect(Events::Types.const_defined?(:CONVERSATION_MENTIONED, false)).to be(false)
    end

    it 'drops the listener and mailer entry points the event fed' do
      expect(ActionCableListener.instance_methods).not_to include(:conversation_mentioned)
      expect(AgentNotifications::ConversationNotificationsMailer.action_methods).not_to include('conversation_mention')
    end

    it 'drops the title translation in every locale that ships one' do
      locales = I18n.available_locales & %i[en es fr it pt pt_BR]
      expect(locales).to include(:en, :pt_BR)

      still_there = locales.select { |l| I18n.exists?('notifications.notification_title.conversation_mention', l) }
      expect(still_there).to be_empty
    end
  end

  describe 'the surviving notification preferences did not move' do
    it 'covers every type the enum still declares' do
      expect(SAVED_BIT_VALUES.keys).to match_array(Notification::NOTIFICATION_TYPES.keys)
    end

    SAVED_BIT_VALUES.each do |type, stored_value|
      it "keeps #{type} on the bit worth #{stored_value}" do
        setting = NotificationSetting.new
        setting.public_send("email_#{type}=", true)
        setting.public_send("push_#{type}=", true)

        expect(setting.email_flags).to eq(stored_value)
        expect(setting.push_flags).to eq(stored_value)
      end
    end

    it 'leaves bit 4 orphaned rather than reused' do
      expect(Notification::NOTIFICATION_TYPES.values).not_to include(4)
      expect(NotificationSetting.new).not_to respond_to(:email_conversation_mention)
    end
  end
end
