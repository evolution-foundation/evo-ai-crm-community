json.access_token resource.access_token.token
json.available_name resource.available_name
json.avatar_url resource.avatar_url
json.confirmed resource.confirmed?
json.display_name resource.display_name
json.message_signature resource.message_signature
json.email resource.email
json.hmac_identifier resource.hmac_identifier if GlobalConfig.get('EVOLUTION_INBOX_HMAC_KEY')['EVOLUTION_INBOX_HMAC_KEY'].present?
json.id resource.id
json.inviter_id nil
json.name resource.name
json.provider resource.provider
json.pubsub_token resource.pubsub_token
json.custom_attributes resource.custom_attributes if resource.custom_attributes.present?
json.role resource.role
json.ui_settings resource.ui_settings
json.uid resource.uid
json.type resource.type
json.accounts do
  json.array! [resource] do |user|
    json.id 1
    json.name GlobalConfig.get('BRAND_NAME')['BRAND_NAME'] || 'AutomaLead'
    json.status 'active'
    json.active_at user.current_sign_in_at
    json.role user.role
    json.permissions user.try(:permissions) || []
    json.availability user.availability
    json.availability_status user.availability_status
    json.auto_offline user.auto_offline
  end
end
