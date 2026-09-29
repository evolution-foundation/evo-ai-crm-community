# frozen_string_literal: true

module Templates
  # Which relation a template bundle may read for a category, given the caller.
  # A router, not a policy: it delegates to the rule that already governs each
  # category. The export inventory, BundleBuilder#base_relation and the import's
  # collision lookup all go through here, so a fix lands on every path at once.
  module VisibilityScope
    # Categories that are not account-wide, mapped to the rule that already governs
    # every other read of them. Everything absent is shared, and scoping it would
    # silently drop assets from bundles.
    RULES = {
      'macros' => ->(user) { ::Macro.with_visibility(user, {}) },
      # Same object Pundit builds for `policy_scope(Pipeline)`, called rather than
      # copied: the service branch and the deliberate lack of an admin bypass are
      # the policy's answers to give.
      'pipelines' => lambda { |user|
        ::PipelinePolicy::Scope.new(
          { user: user, service_authenticated: Current.service_authenticated }, ::Pipeline
        ).resolve
      },
      # An inbox is read by its members, or by an administrator / a holder of
      # conversations.read_all. The rule lives on the user and the policy, and is
      # not visible from the Inbox model, which is how it was missed here.
      'inboxes' => lambda { |user|
        ::InboxPolicy::Scope.new(
          { user: user, service_authenticated: Current.service_authenticated }, ::Inbox
        ).resolve
      }
    }.freeze

    def self.for(category, model, user)
      rule = RULES[category]
      rule ? rule.call(user) : model.all
    end

    # What the export may hand out: nothing of a category the caller may not read,
    # then the category's own rule. The import's collision lookup keeps #for.
    def self.exportable(category, model, user)
      return model.none unless CategoryPermission.readable?(category, user)

      self.for(category, model, user)
    end
  end
end
