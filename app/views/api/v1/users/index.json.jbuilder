json.array! @users do |user|
  json.partial! 'api/v1/models/user', formats: [:json], resource: user
end
