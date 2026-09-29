# frozen_string_literal: true

module Templates
  # templates.export and templates.import are not a way around a category's own
  # permission: exporting reads it, importing creates in it. Each side asks the key the
  # category's own endpoint asks, so a role gets nothing through a bundle that the
  # category's screen would refuse. Resolved the way require_permissions resolves it:
  # a service token passes, a user goes through has_permission?, no administrator bypass.
  module CategoryPermission
    READ = {
      'pipelines' => 'pipelines.read',
      'agents' => 'agent_bots.read',
      'teams' => 'teams.read',
      'labels' => 'labels.read',
      'custom_attributes' => 'custom_attribute_definitions.read',
      'canned_responses' => 'canned_responses.read',
      'macros' => 'macros.read',
      'inboxes' => 'inboxes.read',
      'message_templates' => 'message_templates.read'
    }.freeze

    CREATE = {
      'pipelines' => 'pipelines.create',
      'agents' => 'agent_bots.create',
      'teams' => 'teams.create',
      'labels' => 'labels.create',
      'custom_attributes' => 'custom_attribute_definitions.create',
      'canned_responses' => 'canned_responses.create',
      'macros' => 'macros.manage',
      'inboxes' => 'inboxes.create',
      'message_templates' => 'message_templates.manage'
    }.freeze

    def self.readable?(category, user)
      allowed?(READ.fetch(category), user)
    end

    def self.creatable?(category, user)
      allowed?(CREATE.fetch(category), user)
    end

    def self.create_key(category)
      CREATE.fetch(category)
    end

    def self.allowed?(key, user)
      return true if Current.service_authenticated == true
      return false if user.nil?

      user.has_permission?(key)
    end
    private_class_method :allowed?
  end
end
