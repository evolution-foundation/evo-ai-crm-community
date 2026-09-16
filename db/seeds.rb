# loading installation configs
GlobalConfig.clear_cache
ConfigLoader.new.process

# NOTE: the CRM has no onboarding flow of its own (EVO-2014). The first admin is
# created by the evo-auth-service /setup wizard and synced here on login.

# Agent Knowledge Base: without this, nothing anywhere (no other seed, no UI)
# ever creates a KnowledgeBase row, so on a fresh deployment the feature is
# completely unusable — the frontend's KnowledgePage has nothing to select.
# Runs in every environment (including production), unlike the block below,
# and is idempotent so it's safe to re-run on every deploy.
KnowledgeBase.find_or_create_by!(name: 'Default') do |kb|
  kb.active = true
  kb.default = true
end

## Seeds for Local Development
unless Rails.env.production?

  # Note: User management is now handled by evo-auth-service
  # For development, users should be created through the auth service
  # and then synced to evolution using the authentication endpoints

  # To create users for development:
  # 1. Use the evo-auth-service API to create users
  # 2. Users will be automatically synced to evolution when they authenticate

  # For this seed to work in development, make sure you have users
  # created in evo-auth-service first, then uncomment and adjust the lines below:

  # user = User.find_by(email: 'your-user@example.com')
  # if user.nil?
  #   Rails.logger.warn "⚠️  No user found. Please create users via evo-auth-service first."
  #   Rails.logger.info "💡 Run: rails db:seed in evo-auth-service to create default admin user"
  #   exit 1
  # end


  user = User.find_by(email: "support@evo-auth-service-community.com")

  if user.nil?
    Rails.logger.warn "⚠️  No admin user found with email 'support@evo-auth-service-community.com'"
    Rails.logger.info "💡 Please create this user in evo-auth-service-community first:"
    Rails.logger.info "   1. Start evo-auth-service-community"
    Rails.logger.info "   2. Run: rails db:seed in evo-auth-service-community"
    Rails.logger.info "   3. Then run this seed again"
    Rails.logger.info "🚫 Skipping user-dependent seed data..."
    exit 0
  end

  Rails.logger.info "✅ Found admin user: #{user.email}"

  web_widget = Channel::WebWidget.create!(website_url: 'https://acme.inc')

  inbox = Inbox.create!(channel: web_widget, name: 'Acme Support')
  InboxMember.create!(user: user, inbox: inbox)

  contact_inbox = ContactInboxWithContactBuilder.new(
    source_id: user.id,
    inbox: inbox,
    hmac_verified: true,
    contact_attributes: { name: 'jane', email: 'jane@example.com', phone_number: '+2320000' }
  ).perform

  conversation = Conversation.create!(
    inbox: inbox,
    status: :open,
    assignee: user,
    contact: contact_inbox.contact,
    contact_inbox: contact_inbox,
    additional_attributes: {}
  )

  # sample email collect
  Seeders::MessageSeeder.create_sample_email_collect_message conversation

  Message.create!(content: 'Hello', inbox: inbox, conversation: conversation, sender: contact_inbox.contact,
                  message_type: :incoming)

  # sample location message
  #
  location_message = Message.new(content: 'location', inbox: inbox, sender: contact_inbox.contact, conversation: conversation,
                                 message_type: :incoming)
  location_message.attachments.new(
    file_type: 'location',
    coordinates_lat: 37.7893768,
    coordinates_long: -122.3895553,
    fallback_title: 'Bay Bridge, San Francisco, CA, USA'
  )
  location_message.save!

  # sample card
  Seeders::MessageSeeder.create_sample_cards_message conversation
  # input select
  Seeders::MessageSeeder.create_sample_input_select_message conversation
  # form
  Seeders::MessageSeeder.create_sample_form_message conversation
  # articles
  Seeders::MessageSeeder.create_sample_articles_message conversation
  # csat
  Seeders::MessageSeeder.create_sample_csat_collect_message conversation

  CannedResponse.find_or_create_by!(short_code: 'start') do |canned_response|
    canned_response.content = 'Hello welcome to Evolution Community.'
  end
end
