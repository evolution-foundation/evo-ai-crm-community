# frozen_string_literal: true

class Instagram::ContactProfileFetcher
  PROFILE_FIELDS = 'id,name,username,profile_pic'

  def initialize(inbox:)
    @inbox = inbox
  end

  def call(ig_scope_id)
    if hub?
      HTTParty.get(hub_url(ig_scope_id), headers: hub_auth_headers, open_timeout: 5, read_timeout: 10)
    else
      HTTParty.get(graph_url(ig_scope_id), open_timeout: 5, read_timeout: 10)
    end
  end

  def hub?
    MetaBaseUrl.enabled?
  end

  private

  def hub_url(ig_scope_id)
    "#{MetaBaseUrl.for(:instagram)}/#{ig_scope_id}?fields=#{PROFILE_FIELDS}"
  end

  def graph_url(ig_scope_id)
    version = GlobalConfigService.load('INSTAGRAM_API_VERSION', 'v23.0')
    "https://graph.instagram.com/#{version}/#{ig_scope_id}?fields=#{PROFILE_FIELDS}&access_token=#{@inbox.channel.access_token}"
  end

  def hub_auth_headers
    token = (@inbox.channel.evolution_hub_meta || {})['channel_token']
    { 'Authorization' => "Bearer #{token}" }
  end
end
