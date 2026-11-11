class AddGroupMentionRequiredToAgentBotInboxes < ActiveRecord::Migration[7.1]
  def change
    # Evolution Go groups: the bot only answers when the inbox number is @-mentioned.
    add_column :agent_bot_inboxes, :group_mention_required, :boolean, default: true, null: false, if_not_exists: true
  end
end
