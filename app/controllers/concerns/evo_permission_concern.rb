# frozen_string_literal: true

# Concern para verificacao de permissoes usando evo-auth-service
# Este concern e usado nos controllers APOS a autenticacao
module EvoPermissionConcern
  extend ActiveSupport::Concern
  AUTHZ_REMOTE_CACHE_TTL = 30.seconds

  class_methods do
    # Define multiplas permissoes de uma vez
    def require_permissions(mapping, type: :user)
      mapping.each do |action, permission_key|
        define_method("check_#{action}_permission!") do
          check_permission!(permission_key, type)
        end

        before_action "check_#{action}_permission!".to_sym, only: [action]
      end
    end

    # Define permissao para uma action especifica
    def require_permission(action, permission_key, type: :user)
      define_method("check_#{action}_permission!") do
        check_permission!(permission_key, type)
      end

      before_action "check_#{action}_permission!".to_sym, only: [action]
    end
  end

  private

  # Metodo principal de verificacao de permissao
  def check_permission!(permission_key, type)
    # Se autenticado via service token, permitir acesso (service tokens tem privilegios elevados)
    if Current.service_authenticated == true
      Rails.logger.info "EvoPermission: Service token authenticated - granting access to #{permission_key}"
      return
    end

    # Extrair IDs do contexto atual
    user_id = Current.user&.id

    unless user_id
      Rails.logger.error "EvoPermission: Missing user_id"
      render_permission_denied
      return
    end

    has_permission = has_user_permission?(user_id, permission_key)

    unless has_permission
      Rails.logger.warn "EvoPermission: Access denied - user #{user_id} lacks #{permission_key}"
      render_permission_denied
      return
    end
  end

  # Verificar permissao global de usuario
  def has_user_permission?(user_id, permission)
    Current.evo_permission_cache ||= {}
    cache_key = "user:#{user_id}:#{permission}"
    return Current.evo_permission_cache[cache_key] if Current.evo_permission_cache.key?(cache_key)

    evo_auth_service = EvoAuthService.new
    has_perm = evo_auth_service.check_user_permission(user_id, permission)
    Current.evo_permission_cache[cache_key] = has_perm

    has_perm
  rescue StandardError => e
    Rails.logger.error "Error checking permission #{permission} for user #{user_id}: #{e.message}"

    # Em caso de erro, negar acesso por seguranca
    false
  end

  def render_permission_denied
    render json: {
      error: 'Forbidden - Insufficient permissions',
      message: 'You do not have the required permissions to access this resource'
    }, status: :forbidden
  end

  # Helper method para verificar permissao especifica
  def can_perform_action?(resource, action, user_id = nil)
    user_id ||= Current.user&.id

    return false unless user_id

    permission = "#{resource}.#{action}"
    has_user_permission?(user_id, permission)
  end
end
