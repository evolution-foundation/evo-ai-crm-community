# frozen_string_literal: true

require_relative '../../lib/action_cable_log_redaction'

# after_initialize: the engine assigns `logger ||= Rails.logger` on the action_cable
# load hook, and touching ActionCable.server here forces that hook first.
Rails.application.config.after_initialize do
  ActionCableLogRedaction.install!(ActionCable.server.config)
end
