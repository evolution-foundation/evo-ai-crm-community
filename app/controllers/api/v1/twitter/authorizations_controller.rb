class Api::V1::Twitter::AuthorizationsController < Api::V1::BaseController
  require_permissions({
    index: 'twitter_authorizations.read',
    show: 'twitter_authorizations.read',
    create: 'twitter_authorizations.create',
    update: 'twitter_authorizations.update',
    destroy: 'twitter_authorizations.delete'
  })
  include TwitterConcern

  

  def create
    @response = twitter_client.request_oauth_token(url: twitter_callback_url)
    if @response.status == '200'
      ::Redis::Alfred.setex(oauth_token, 'community')
      render json: { success: true, url: oauth_authorize_endpoint(oauth_token) }
    else
      render json: { success: false }, status: :unprocessable_entity
    end
  end

  private

  def oauth_token
    parsed_body['oauth_token']
  end

  def oauth_authorize_endpoint(oauth_token)
    "#{twitter_api_base_url}/oauth/authorize?oauth_token=#{oauth_token}"
  end

end
