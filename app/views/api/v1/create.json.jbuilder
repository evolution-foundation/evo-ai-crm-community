json.data do
  json.id resource.id
  json.provider resource.provider
  json.uid resource.uid
  json.name resource.name
  json.display_name resource.display_name
  json.email resource.email
  json.created_at resource.created_at
  json.pubsub_token resource.pubsub_token
  json.role resource.role
  json.inviter_id nil
  json.confirmed resource.confirmed?
  json.avatar_url resource.avatar_url
  json.access_token resource.access_token.token
  json.accounts do
    json.array! [resource] do |user|
      json.id 1
      json.name GlobalConfig.get('BRAND_NAME')['BRAND_NAME'] || 'Evo CRM'
      json.active_at user.current_sign_in_at
      json.role user.role
      json.locale ENV.fetch('DEFAULT_LOCALE', 'en')
    end
  end
end
