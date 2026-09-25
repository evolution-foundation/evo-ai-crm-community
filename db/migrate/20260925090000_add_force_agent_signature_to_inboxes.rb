# frozen_string_literal: true

# When enabled, every outgoing human-agent message on this inbox gets the
# agent's display-name prefix applied automatically (Message#apply_human_agent_signature) —
# the agent has no per-message choice, unlike the existing manual composer toggle.
class AddForceAgentSignatureToInboxes < ActiveRecord::Migration[7.1]
  def change
    add_column :inboxes, :force_agent_signature, :boolean, default: false, null: false, if_not_exists: true
  end
end
