# Herda diretamente do controller de accounts
class Api::V1::Oauth::ContactsController < Api::V1::ContactsController
  require_permissions({
    index: 'oauth_contacts.read',
    show: 'oauth_contacts.read',
    create: 'oauth_contacts.create',
    update: 'oauth_contacts.update',
    destroy: 'oauth_contacts.delete'
  })

  # Remove parent controller middlewares for OAuth
  skip_before_action :authenticate_request!
  skip_before_action :fetch_contact
  skip_before_action :set_include_contact_inboxes

  # Aplica middleware OAuth
  include Doorkeeper::Rails::Helpers
  include OauthAccountHelper
  before_action :ensure_oauth_authentication!
  before_action :fetch_contact, only: [:show, :update, :destroy, :avatar, :contactable_inboxes, :destroy_custom_attributes]
  before_action :set_include_contact_inboxes, only: [:index, :active, :search, :filter, :show, :update]

  private

  def ensure_oauth_authentication!
    unless oauth_token_present?
      render_unauthorized('OAuth token required. This endpoint only accepts OAuth authentication.')
      return
    end

    # Verificar se o token é válido antes de chamar doorkeeper
    token = Doorkeeper::AccessToken.by_token(doorkeeper_token_value)
    unless token&.accessible?
      render_unauthorized('Invalid or expired OAuth token')
      return
    end

    # Verificar se tem escopo adequado
    unless token.acceptable?(['admin']) || token.acceptable?(['read']) || token.acceptable?(['contacts:read'])
      render_unauthorized('Insufficient scope for this endpoint')
      return
    end

    # Token válido, continuar com autenticação
    @resource = User.find(token.resource_owner_id) if token.resource_owner_id
    Current.user = @resource if @resource
  end

  def doorkeeper_token_value
    request.headers['Authorization']&.gsub(/^Bearer\s+/, '')
  end

  def fetch_contact
    @contact = Contact.all.includes(contact_inboxes: [:inbox]).find(params[:id])
  end

  def set_include_contact_inboxes
    @include_contact_inboxes = if params[:include_contact_inboxes].present?
                                 params[:include_contact_inboxes] == 'true'
                               else
                                 true
                               end
  end
end
