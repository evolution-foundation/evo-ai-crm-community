# rubocop:disable Metrics/ModuleLength
module OauthAuthorizationHelper
  extend ActiveSupport::Concern

  # Mapear scopes OAuth para permissões de API
  SCOPE_PERMISSIONS = {
    # Scopes básicos (legacy - manter compatibilidade)
    'read' => %w[show index],
    'write' => %w[create update destroy],

    # Recursos principais
    'conversations' => { actions: %w[show index create update toggle_status toggle_priority filter search attachments], controller: 'conversations' },
    'contacts' => {
      actions: %w[show index create update destroy search filter avatar contactable_inboxes destroy_custom_attributes],
      controller: 'contacts'
    },
    'messages' => { actions: %w[show index create update], controller: 'messages' },
    'inboxes' => { actions: %w[show index create update destroy avatar set_agent_bot assignable_agents campaigns], controller: 'inboxes' },
    'agents' => { actions: %w[index create update destroy bulk_create], controller: 'agents' },
    'reports' => { actions: %w[show index], controller: 'reports' },

    # Novos recursos - Gestão de Pipelines
    'pipelines:read' => { actions: %w[show index stats], controller: 'pipelines' },
    'pipelines:write' => { actions: %w[create update destroy archive], controller: 'pipelines' },
    'pipeline_stages:read' => { actions: %w[show index], controller: 'pipeline_stages' },
    'pipeline_stages:write' => { actions: %w[create update destroy], controller: 'pipeline_stages' },
    'pipeline_items:read' => { actions: %w[show index], controller: 'pipeline_items' },
    'pipeline_items:write' => { actions: %w[update move_to_stage update_custom_fields], controller: 'pipeline_items' },

    # Knowledge Base
    'knowledge_base:read' => [
    ],
    'knowledge_base:write' => [
    ],

    # Automação e Bots
    'bots:read' => { actions: %w[show index], controller: 'agent_bots' },
    'bots:write' => { actions: %w[create update destroy], controller: 'agent_bots' },
    'automations:read' => { actions: %w[show index], controller: 'automation_rules' },
    'automations:write' => { actions: %w[create update destroy], controller: 'automation_rules' },
    'macros:read' => { actions: %w[show index], controller: 'macros' },
    'macros:write' => { actions: %w[create update destroy], controller: 'macros' },
    'macros:execute' => { actions: %w[execute], controller: 'macros' },

    # Campanhas
    'campaigns:read' => { actions: %w[show index], controller: 'campaigns' },
    'campaigns:write' => { actions: %w[create update destroy], controller: 'campaigns' },

    # Organização
    'labels:read' => { actions: %w[show index], controller: 'labels' },
    'labels:write' => { actions: %w[create update destroy], controller: 'labels' },
    'teams:read' => { actions: %w[show index], controller: 'teams' },
    'teams:write' => [
      { actions: %w[create update destroy], controller: 'teams' },
      { actions: %w[index create update destroy], controller: 'team_members' }
    ],
    'custom_attributes:read' => { actions: %w[show index], controller: 'custom_attribute_definitions' },
    'custom_attributes:write' => { actions: %w[create update destroy], controller: 'custom_attribute_definitions' },
    'filters:read' => { actions: %w[show index], controller: 'custom_filters' },
    'filters:write' => { actions: %w[create update destroy], controller: 'custom_filters' },

    # Integrações e Webhooks
    'webhooks:read' => { actions: %w[index], controller: 'webhooks' },
    'webhooks:write' => { actions: %w[create update destroy], controller: 'webhooks' },
    'integrations:read' => { actions: %w[show index teams team_entities linked_issues], controller: %w[dashboard_apps linear] },
    'integrations:write' => { actions: %w[create update destroy create_issue link_issue unlink_issue], controller: %w[dashboard_apps linear] },
    'channels:read' => { actions: %w[show index], controller: %w[twilio_channels] },
    'channels:write' => { actions: %w[create update destroy], controller: %w[twilio_channels] },

    # Configurações
    'settings:read' => [
      { actions: %w[show], controller: 'working_hours' },
      { actions: %w[show], controller: 'notification_settings' }
    ],
    'settings:write' => [
      { actions: %w[update], controller: 'working_hours' },
      { actions: %w[update], controller: 'notification_settings' }
    ],
    'canned_responses:read' => { actions: %w[show index], controller: 'canned_responses' },
    'canned_responses:write' => { actions: %w[create update destroy], controller: 'canned_responses' },

    # Operações
    'search:read' => { actions: %w[index conversations contacts messages], controller: 'search' },
    'surveys:read' => { actions: %w[show index], controller: 'csat_survey_responses' },
    'surveys:write' => { actions: %w[create update destroy], controller: 'csat_survey_responses' },
    'uploads:write' => { actions: %w[create], controller: 'upload' },
    'bulk_actions:write' => { actions: %w[create], controller: 'bulk_actions' },
    'notifications:read' => { actions: %w[index], controller: 'notifications' },
    'notifications:write' => { actions: %w[update_primary_actor], controller: 'notifications' },

    # Admin - acesso total (manter legacy)
    'admin' => %w[all]
  }.freeze

  def authenticate_oauth_token!
    doorkeeper_authorize!
    @resource = current_resource_owner
    Current.user = @resource if @resource
  end

  def validate_oauth_scope!(required_scope = nil)
    required_scope ||= detect_required_scope
    return if doorkeeper_token.acceptable?(required_scope)

    render_unauthorized("Insufficient scope. Required: #{required_scope}")
  end

  private

  def detect_required_scope
    controller = params[:controller].split('/').last
    action = params[:action]

    # Verificar se há scope específico para o controller
    SCOPE_PERMISSIONS.each do |scope, config|
      return scope if scope_matches?(config, controller, action)
    end

    # Fallback para scopes básicos
    case action
    when 'create', 'update', 'destroy'
      'write'
    else
      'read'
    end
  end

  def scope_matches?(config, controller, action)
    case config
    when Hash
      # Configuração única de controller
      controller_matches?(config[:controller], controller) && config[:actions].include?(action)
    when Array
      # Array de configurações (para scopes que cobrem múltiplos controllers)
      config.any? do |sub_config|
        controller_matches?(sub_config[:controller], controller) && sub_config[:actions].include?(action)
      end
    else
      # Configuração simples (array de actions)
      config.include?(action)
    end
  end

  def controller_matches?(scope_controller, request_controller)
    case scope_controller
    when String
      scope_controller == request_controller
    when Array
      scope_controller.include?(request_controller)
    else
      false
    end
  end

  def current_resource_owner
    User.find(doorkeeper_token.resource_owner_id) if doorkeeper_token
  end

  def render_unauthorized(message = 'Unauthorized')
    render json: { error: message }, status: :unauthorized
  end
end
# rubocop:enable Metrics/ModuleLength
