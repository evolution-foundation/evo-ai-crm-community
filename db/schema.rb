# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 9025_08_19_224901) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_stat_statements"
  enable_extension "pg_trgm"
  enable_extension "pgcrypto"
  enable_extension "plpgsql"
  enable_extension "uuid-ossp"

  # Custom types defined in this database.
  # Note that some types may not work with other database engines. Be careful if changing database.
  create_enum "contact_type_enum", ["person", "company"]

  create_table "access_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", limit: 255, null: false
    t.string "owner_type"
    t.string "scopes", null: false
    t.uuid "owner_id"
    t.string "token"
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.uuid "issued_id"
    t.index ["issued_id"], name: "index_access_tokens_on_issued_id"
    t.index ["owner_type", "owner_id"], name: "index_access_tokens_on_owner_type_and_owner_id"
    t.index ["token"], name: "index_access_tokens_on_token", unique: true
  end

  create_table "action_mailbox_inbound_emails", force: :cascade do |t|
    t.integer "status", default: 0, null: false
    t.string "message_id", null: false
    t.string "message_checksum", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["message_id", "message_checksum"], name: "index_action_mailbox_inbound_emails_uniqueness", unique: true
  end

  create_table "active_storage_attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.uuid "record_id", null: false
    t.uuid "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "agent_bot_inboxes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "inbox_id"
    t.uuid "agent_bot_id"
    t.integer "status", default: 0
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "allowed_conversation_statuses", default: [], null: false
    t.jsonb "allowed_label_ids", default: [], null: false
    t.boolean "facebook_comment_replies_enabled", default: false, null: false
    t.uuid "facebook_comment_agent_bot_id"
    t.jsonb "ignored_label_ids", default: [], null: false
    t.string "facebook_interaction_type", default: "both", null: false
    t.jsonb "facebook_allowed_post_ids", default: [], null: false
    t.boolean "moderation_enabled", default: false, null: false
    t.jsonb "explicit_words_filter", default: [], null: false
    t.boolean "sentiment_analysis_enabled", default: false, null: false
    t.boolean "auto_approve_responses", default: false, null: false
    t.boolean "auto_reject_explicit_words", default: false, null: false
    t.boolean "auto_reject_offensive_sentiment", default: false, null: false
    t.index ["allowed_conversation_statuses"], name: "index_agent_bot_inboxes_on_allowed_conversation_statuses", using: :gin
    t.index ["allowed_label_ids"], name: "index_agent_bot_inboxes_on_allowed_label_ids", using: :gin
    t.index ["auto_reject_explicit_words"], name: "index_agent_bot_inboxes_on_auto_reject_explicit_words"
    t.index ["auto_reject_offensive_sentiment"], name: "index_agent_bot_inboxes_on_auto_reject_offensive_sentiment"
    t.index ["explicit_words_filter"], name: "index_agent_bot_inboxes_on_explicit_words_filter", using: :gin
    t.index ["facebook_allowed_post_ids"], name: "index_agent_bot_inboxes_on_facebook_allowed_post_ids", using: :gin
    t.index ["facebook_comment_agent_bot_id"], name: "index_agent_bot_inboxes_on_facebook_comment_agent_bot_id"
    t.index ["facebook_interaction_type"], name: "index_agent_bot_inboxes_on_facebook_interaction_type"
    t.index ["ignored_label_ids"], name: "index_agent_bot_inboxes_on_ignored_label_ids", using: :gin
    t.index ["moderation_enabled"], name: "index_agent_bot_inboxes_on_moderation_enabled"
  end

  create_table "agent_bots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.string "description"
    t.string "outgoing_url"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "bot_type", default: 0
    t.jsonb "bot_config", default: {}
    t.string "api_key"
    t.string "bot_provider", default: "webhook", null: false
    t.text "message_signature"
    t.boolean "text_segmentation_enabled", default: false, null: false
    t.integer "text_segmentation_limit", default: 300
    t.integer "text_segmentation_min_size", default: 50
    t.decimal "delay_per_character", precision: 8, scale: 2, default: "50.0"
    t.integer "debounce_time", default: 5, null: false
  end

  create_table "alembic_version", primary_key: "version_num", id: { type: :string, limit: 32 }, force: :cascade do |t|
  end

  create_table "app_states", primary_key: "app_name", id: { type: :string, limit: 128 }, force: :cascade do |t|
    t.jsonb "state", null: false
    t.datetime "update_time", precision: nil, null: false
  end

  create_table "attachments", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "file_type", default: 0
    t.string "external_url"
    t.float "coordinates_lat", default: 0.0
    t.float "coordinates_long", default: 0.0
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "fallback_title"
    t.string "extension"
    t.jsonb "meta", default: {}
    t.string "attachable_type"
    t.uuid "attachable_id"
    t.index ["attachable_type", "attachable_id"], name: "index_attachments_on_attachable_type_and_attachable_id"
  end

  create_table "automation_rules", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.string "event_name", null: false
    t.jsonb "conditions", default: "{}", null: false
    t.jsonb "actions", default: "{}", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "active", default: true, null: false
    t.string "mode", default: "simple", null: false
    t.jsonb "flow_data"
    t.index ["flow_data"], name: "index_automation_rules_on_flow_data", using: :gin
    t.index ["mode"], name: "index_automation_rules_on_mode"
  end

  create_table "canned_responses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "short_code"
    t.text "content"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "channel_api", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "webhook_url"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "identifier"
    t.string "hmac_token"
    t.boolean "hmac_mandatory", default: false
    t.jsonb "additional_attributes", default: {}
    t.index ["hmac_token"], name: "index_channel_api_on_hmac_token", unique: true
    t.index ["identifier"], name: "index_channel_api_on_identifier", unique: true
  end

  create_table "channel_email", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "email", null: false
    t.string "forward_to_email", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "imap_enabled", default: false
    t.string "imap_address", default: ""
    t.integer "imap_port", default: 0
    t.string "imap_login", default: ""
    t.string "imap_password", default: ""
    t.boolean "imap_enable_ssl", default: true
    t.boolean "smtp_enabled", default: false
    t.string "smtp_address", default: ""
    t.integer "smtp_port", default: 0
    t.string "smtp_login", default: ""
    t.string "smtp_password", default: ""
    t.string "smtp_domain", default: ""
    t.boolean "smtp_enable_starttls_auto", default: true
    t.string "smtp_authentication", default: "login"
    t.string "smtp_openssl_verify_mode", default: "none"
    t.boolean "smtp_enable_ssl_tls", default: false
    t.jsonb "provider_config", default: {}
    t.string "provider"
    t.text "email_signature"
    t.index ["email"], name: "index_channel_email_on_email", unique: true
    t.index ["forward_to_email"], name: "index_channel_email_on_forward_to_email", unique: true
  end

  create_table "channel_facebook_pages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "page_id", null: false
    t.string "user_access_token", null: false
    t.string "page_access_token", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "instagram_id"
    t.index ["page_id"], name: "index_channel_facebook_pages_on_page_id", unique: true
  end

  create_table "channel_instagram", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "access_token", null: false
    t.datetime "expires_at", precision: nil, null: false
    t.string "instagram_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["instagram_id"], name: "index_channel_instagram_on_instagram_id", unique: true
  end

  create_table "channel_line", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "line_channel_id", null: false
    t.string "line_channel_secret", null: false
    t.string "line_channel_token", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["line_channel_id"], name: "index_channel_line_on_line_channel_id", unique: true
  end

  create_table "channel_sms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "phone_number", null: false
    t.string "provider", default: "default"
    t.jsonb "provider_config", default: {}
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["phone_number"], name: "index_channel_sms_on_phone_number", unique: true
  end

  create_table "channel_telegram", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "bot_name"
    t.string "bot_token", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["bot_token"], name: "index_channel_telegram_on_bot_token", unique: true
  end

  create_table "channel_twilio_sms", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "phone_number"
    t.string "auth_token", null: false
    t.string "account_sid", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "medium", default: 0
    t.string "messaging_service_sid"
    t.string "api_key_sid"
    t.index ["account_sid", "phone_number"], name: "index_channel_twilio_sms_on_account_sid_and_phone_number", unique: true
    t.index ["messaging_service_sid"], name: "index_channel_twilio_sms_on_messaging_service_sid", unique: true
    t.index ["phone_number"], name: "index_channel_twilio_sms_on_phone_number", unique: true
  end

  create_table "channel_twitter_profiles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "profile_id", null: false
    t.string "twitter_access_token", null: false
    t.string "twitter_access_token_secret", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "tweets_enabled", default: true
    t.index ["profile_id"], name: "index_channel_twitter_profiles_on_profile_id", unique: true
  end

  create_table "channel_web_widgets", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "website_url"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "website_token"
    t.string "widget_color", default: "#1f93ff"
    t.string "welcome_title"
    t.string "welcome_tagline"
    t.integer "feature_flags", default: 7, null: false
    t.integer "reply_time", default: 0
    t.string "hmac_token"
    t.boolean "pre_chat_form_enabled", default: false
    t.jsonb "pre_chat_form_options", default: {}
    t.boolean "hmac_mandatory", default: false
    t.boolean "continuity_via_email", default: true, null: false
    t.string "locale"
    t.index ["hmac_token"], name: "index_channel_web_widgets_on_hmac_token", unique: true
    t.index ["website_token"], name: "index_channel_web_widgets_on_website_token", unique: true
  end

  create_table "channel_whatsapp", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "phone_number", null: false
    t.string "provider", default: "default"
    t.jsonb "provider_config", default: {}
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "provider_connection", default: {}
    t.index ["phone_number"], name: "index_channel_whatsapp_on_phone_number", unique: true
  end

  create_table "contact_companies", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "contact_id", null: false
    t.uuid "company_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "deleted_at"
    t.index ["company_id", "contact_id"], name: "index_contact_companies_on_company_id_and_contact_id"
    t.index ["contact_id", "company_id"], name: "index_contact_companies_on_contact_id_and_company_id", unique: true
    t.index ["deleted_at"], name: "index_contact_companies_on_deleted_at"
  end

  create_table "contact_inboxes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "contact_id"
    t.uuid "inbox_id"
    t.string "source_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "hmac_verified", default: false
    t.string "pubsub_token"
    t.index ["contact_id"], name: "index_contact_inboxes_on_contact_id"
    t.index ["inbox_id", "source_id"], name: "index_contact_inboxes_on_inbox_id_and_source_id", unique: true
    t.index ["inbox_id"], name: "index_contact_inboxes_on_inbox_id"
    t.index ["pubsub_token"], name: "index_contact_inboxes_on_pubsub_token", unique: true
    t.index ["source_id"], name: "index_contact_inboxes_on_source_id"
  end

  create_table "contacts", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", default: ""
    t.string "email"
    t.string "phone_number"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "additional_attributes", default: {}
    t.string "identifier"
    t.jsonb "custom_attributes", default: {}
    t.datetime "last_activity_at", precision: nil
    t.integer "contact_type", default: 0
    t.string "middle_name", default: ""
    t.string "last_name", default: ""
    t.string "location", default: ""
    t.string "country_code", default: ""
    t.boolean "blocked", default: false, null: false
    t.enum "type", default: "person", null: false, enum_type: "contact_type_enum"
    t.string "tax_id", limit: 14
    t.string "website"
    t.string "industry"
    t.index ["blocked"], name: "index_contacts_on_blocked"
    t.index ["email"], name: "uniq_email_per_account_contact", unique: true
    t.index ["identifier"], name: "uniq_identifier_per_account_contact", unique: true
    t.index ["last_activity_at"], name: "index_contacts_on_last_activity_at", order: "DESC NULLS LAST"
    t.index ["name", "email", "phone_number", "identifier"], name: "index_contacts_on_name_email_phone_number_identifier", opclass: :gin_trgm_ops, using: :gin
    t.index ["phone_number"], name: "index_contacts_on_phone_number"
    t.index ["tax_id"], name: "index_contacts_on_tax_id", unique: true, where: "(tax_id IS NOT NULL)"
    t.index ["type"], name: "index_contacts_on_type"
  end

  create_table "conversation_participants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "conversation_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["conversation_id"], name: "index_conversation_participants_on_conversation_id"
    t.index ["user_id", "conversation_id"], name: "index_conversation_participants_on_user_id_and_conversation_id", unique: true
    t.index ["user_id"], name: "index_conversation_participants_on_user_id"
  end

  create_table "conversations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "inbox_id", null: false
    t.integer "status", default: 0, null: false
    t.uuid "assignee_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.uuid "contact_id"
    t.integer "display_id", null: false
    t.datetime "contact_last_seen_at", precision: nil
    t.datetime "agent_last_seen_at", precision: nil
    t.jsonb "additional_attributes", default: {}
    t.uuid "contact_inbox_id"
    t.uuid "uuid", default: -> { "gen_random_uuid()" }, null: false
    t.string "identifier"
    t.datetime "last_activity_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.uuid "team_id"
    t.datetime "snoozed_until", precision: nil
    t.jsonb "custom_attributes", default: {}
    t.datetime "assignee_last_seen_at", precision: nil
    t.datetime "first_reply_created_at", precision: nil
    t.integer "priority"
    t.datetime "waiting_since", precision: nil
    t.text "cached_label_list"
    t.index ["assignee_id", "status", "last_activity_at"], name: "index_conversations_on_assignee_status_last_activity", order: { last_activity_at: "DESC NULLS LAST" }
    t.index ["assignee_id"], name: "index_conversations_on_assignee_id"
    t.index ["contact_id"], name: "index_conversations_on_contact_id"
    t.index ["contact_inbox_id"], name: "index_conversations_on_contact_inbox_id"
    t.index ["display_id"], name: "index_conversations_on_display_id", unique: true
    t.index ["first_reply_created_at"], name: "index_conversations_on_first_reply_created_at"
    t.index ["inbox_id", "status", "assignee_id"], name: "conv_inbid_stat_asgnid_idx"
    t.index ["inbox_id", "status", "last_activity_at"], name: "index_conversations_on_inbox_status_last_activity", order: { last_activity_at: "DESC NULLS LAST" }
    t.index ["inbox_id"], name: "index_conversations_on_inbox_id"
    t.index ["priority"], name: "index_conversations_on_priority"
    t.index ["status", "last_activity_at"], name: "index_conversations_on_status_last_activity", order: { last_activity_at: "DESC NULLS LAST" }
    t.index ["status", "priority"], name: "index_conversations_on_status_and_priority"
    t.index ["status"], name: "index_conversations_on_status"
    t.index ["team_id"], name: "index_conversations_on_team_id"
    t.index ["uuid"], name: "index_conversations_on_uuid", unique: true
    t.index ["waiting_since"], name: "index_conversations_on_waiting_since"
  end

  create_table "csat_survey_responses", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.uuid "message_id", null: false
    t.integer "rating", null: false
    t.text "feedback_message"
    t.uuid "contact_id", null: false
    t.uuid "assigned_agent_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["assigned_agent_id"], name: "index_csat_survey_responses_on_assigned_agent_id"
    t.index ["contact_id"], name: "index_csat_survey_responses_on_contact_id"
    t.index ["conversation_id"], name: "index_csat_survey_responses_on_conversation_id"
    t.index ["message_id"], name: "index_csat_survey_responses_on_message_id", unique: true
  end

  create_table "custom_attribute_definitions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "attribute_display_name"
    t.string "attribute_key"
    t.integer "attribute_display_type", default: 0
    t.integer "default_value"
    t.integer "attribute_model", default: 0
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.text "attribute_description"
    t.jsonb "attribute_values", default: []
    t.string "regex_pattern"
    t.string "regex_cue"
    t.index ["attribute_key", "attribute_model"], name: "attribute_key_model_index", unique: true
  end

  create_table "custom_filters", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.integer "filter_type", default: 0, null: false
    t.jsonb "query", default: "{}", null: false
    t.uuid "user_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["user_id"], name: "index_custom_filters_on_user_id"
  end

  create_table "dashboard_apps", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "title", null: false
    t.jsonb "content", default: []
    t.uuid "user_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "display_type", default: "conversation"
    t.string "sidebar_menu", default: "conversations"
    t.string "sidebar_position", default: "after"
    t.index ["user_id"], name: "index_dashboard_apps_on_user_id"
  end

  create_table "data_imports", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "data_type", null: false
    t.integer "status", default: 0, null: false
    t.text "processing_errors"
    t.integer "total_records"
    t.integer "processed_records"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "data_privacy_consents", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "consent_type", null: false
    t.boolean "granted", default: false, null: false
    t.datetime "granted_at"
    t.datetime "revoked_at"
    t.string "ip_address"
    t.text "user_agent"
    t.jsonb "details", default: {}
    t.string "legal_basis"
    t.text "purpose_description"
    t.datetime "expires_at"
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["consent_type"], name: "index_data_privacy_consents_on_consent_type"
    t.index ["expires_at"], name: "index_data_privacy_consents_on_expires_at"
    t.index ["granted"], name: "index_data_privacy_consents_on_granted"
    t.index ["granted_at"], name: "index_data_privacy_consents_on_granted_at"
    t.index ["user_id", "consent_type"], name: "index_data_privacy_consents_on_user_id_and_consent_type", unique: true
    t.index ["user_id"], name: "index_data_privacy_consents_on_user_id"
  end

  create_table "events", primary_key: ["id", "app_name", "user_id", "session_id"], force: :cascade do |t|
    t.string "id", limit: 128, null: false
    t.string "app_name", limit: 128, null: false
    t.string "user_id", limit: 128, null: false
    t.string "session_id", limit: 128, null: false
    t.string "invocation_id", limit: 256, null: false
    t.string "author", limit: 256, null: false
    t.binary "actions", null: false
    t.text "long_running_tool_ids_json"
    t.string "branch", limit: 256
    t.datetime "timestamp", precision: nil, null: false
    t.jsonb "content"
    t.jsonb "grounding_metadata"
    t.jsonb "custom_metadata"
    t.jsonb "usage_metadata"
    t.jsonb "citation_metadata"
    t.boolean "partial"
    t.boolean "turn_complete"
    t.string "error_code", limit: 256
    t.string "error_message", limit: 1024
    t.boolean "interrupted"
    t.jsonb "input_transcription"
    t.jsonb "output_transcription"
  end

  create_table "evo_agent_processor_execution_metrics", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "agent_id"
    t.string "session_id", null: false
    t.string "user_id", null: false
    t.string "llm_model", null: false
    t.integer "prompt_tokens", null: false
    t.integer "candidate_tokens", null: false
    t.float "cost", null: false
    t.integer "total_tokens", null: false
    t.timestamptz "created_at", default: -> { "now()" }
  end

  create_table "evo_ai_agent_processor_execution_metrics", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "agent_id"
    t.string "session_id", null: false
    t.string "user_id", null: false
    t.string "llm_model", null: false
    t.integer "prompt_tokens", null: false
    t.integer "candidate_tokens", null: false
    t.float "cost", null: false
    t.integer "total_tokens", null: false
    t.timestamptz "created_at", default: -> { "now()" }
  end

  create_table "evo_ai_agent_processor_session_metadata", primary_key: "session_id", id: :string, force: :cascade do |t|
    t.string "name"
    t.text "description"
    t.json "tags"
    t.string "created_by_user_id"
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at"
  end

  create_table "evo_ai_agent_processor_sessions", id: :string, force: :cascade do |t|
    t.string "app_name"
    t.string "user_id"
    t.json "state"
    t.timestamptz "create_time"
    t.timestamptz "update_time"
  end

  create_table "evo_core_agent_folders", id: :uuid, default: nil, force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at"
  end

  create_table "evo_core_agent_integrations", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.uuid "agent_id", null: false
    t.string "provider", limit: 100, null: false
    t.jsonb "config", default: {}
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["agent_id"], name: "idx_evo_core_agent_integrations_agent"
    t.index ["provider"], name: "idx_evo_core_agent_integrations_provider"
    t.unique_constraint ["agent_id", "provider"], name: "unique_agent_integration"
  end

  create_table "evo_core_agents", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.string "name", limit: 255, null: false
    t.text "description"
    t.string "type", limit: 10, null: false
    t.string "model", limit: 255
    t.uuid "api_key_id"
    t.text "instruction"
    t.string "card_url", limit: 1024, null: false
    t.uuid "folder_id"
    t.json "config", default: {}
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.uuid "evolution_bot_id"
    t.boolean "evolution_bot_sync", default: false, null: false
    t.text "role"
    t.text "goal"
    t.index ["evolution_bot_id"], name: "idx_agents_evolution_bot_id"
    t.index ["evolution_bot_sync"], name: "idx_agents_evolution_bot_sync"
    t.index ["name"], name: "idx_evo_core_agents_name"
    t.index ["name"], name: "idx_evo_core_agents_name_unique", unique: true
    t.check_constraint "type::text = ANY (ARRAY['llm'::character varying::text, 'sequential'::character varying::text, 'parallel'::character varying::text, 'loop'::character varying::text, 'a2a'::character varying::text, 'workflow'::character varying::text, 'crew_ai'::character varying::text, 'task'::character varying::text, 'external'::character varying::text])", name: "check_agent_type"
  end

  create_table "evo_core_api_keys", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.string "name", limit: 255, null: false
    t.string "provider", limit: 255, null: false
    t.text "key", null: false
    t.boolean "is_active", default: true
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at", default: -> { "now()" }
    t.index ["is_active"], name: "idx_evo_core_api_keys_is_active"
    t.index ["name"], name: "idx_evo_core_api_keys_name"
    t.index ["name"], name: "idx_evo_core_api_keys_name_unique", unique: true
  end

  create_table "evo_core_custom_mcp_servers", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.string "name", limit: 255, null: false
    t.text "description"
    t.string "url", limit: 1024, null: false
    t.json "headers", null: false
    t.integer "timeout", default: 0, null: false
    t.integer "retry_count", default: 0, null: false
    t.string "tags", limit: 255, default: [], null: false, array: true
    t.json "tools", default: {}, null: false
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at", default: -> { "now()" }
    t.index ["name"], name: "idx_evo_core_custom_mcp_servers_name"
    t.index ["name"], name: "idx_evo_core_custom_mcp_servers_name_unique", unique: true
  end

  create_table "evo_core_custom_tools", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.string "name", limit: 255, null: false
    t.text "description"
    t.string "method", limit: 10, null: false
    t.string "endpoint", limit: 1024, null: false
    t.json "headers", null: false
    t.json "path_params", null: false
    t.json "query_params", null: false
    t.json "body_params", null: false
    t.json "error_handling", null: false
    t.json "values", null: false
    t.string "tags", limit: 255, default: [], null: false, array: true
    t.string "examples", limit: 255, default: [], null: false, array: true
    t.string "input_modes", limit: 255, default: [], null: false, array: true
    t.string "output_modes", limit: 255, default: [], null: false, array: true
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at", default: -> { "now()" }
    t.index ["name"], name: "idx_evo_core_custom_tools_name"
    t.index ["name"], name: "idx_evo_core_custom_tools_name_unique", unique: true
  end

  create_table "evo_core_folder_shares", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.uuid "folder_id"
    t.uuid "shared_by_user_id"
    t.string "shared_with_email", limit: 255, null: false
    t.uuid "shared_with_user_id"
    t.string "permission_level", limit: 5, null: false
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["folder_id"], name: "idx_evo_core_folder_shares_folder_id"
    t.index ["shared_by_user_id"], name: "idx_evo_core_folder_shares_shared_by_user_id"
    t.index ["shared_with_user_id"], name: "idx_evo_core_folder_shares_shared_with_user_id"
    t.check_constraint "permission_level::text = ANY (ARRAY['read'::text, 'write'::text])", name: "check_permission_level"
  end

  create_table "evo_core_folders", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.string "name", limit: 255, null: false
    t.text "description"
    t.datetime "created_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.datetime "updated_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.index ["name"], name: "idx_evo_core_folders_name"
    t.index ["name"], name: "idx_evo_core_folders_name_unique", unique: true
  end

  create_table "evo_core_mcp_servers", id: :uuid, default: -> { "uuid_generate_v4()" }, force: :cascade do |t|
    t.string "name", limit: 255, null: false
    t.text "description"
    t.string "config_type", limit: 10, null: false
    t.json "config_json", null: false
    t.json "environments", null: false
    t.json "tools", null: false
    t.string "type", limit: 10, null: false
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at", default: -> { "now()" }
    t.index ["name"], name: "idx_evo_core_mcp_servers_name", unique: true
    t.check_constraint "config_type::text = ANY (ARRAY['studio'::text, 'sse'::text])", name: "check_mcp_server_config_type"
    t.check_constraint "type::text = ANY (ARRAY['official'::text, 'community'::text])", name: "check_mcp_server_type"
  end

  create_table "evo_core_schema_community_migrations", primary_key: "version", id: :bigint, default: nil, force: :cascade do |t|
    t.boolean "dirty", null: false
  end

  create_table "facebook_comment_moderations", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.uuid "message_id", null: false
    t.string "comment_id", null: false
    t.string "moderation_type", null: false
    t.string "status", default: "pending", null: false
    t.string "action_type", null: false
    t.text "response_content"
    t.text "rejection_reason"
    t.uuid "moderated_by_id"
    t.datetime "moderated_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "sentiment_offensive", default: false, null: false
    t.float "sentiment_confidence", default: 0.0, null: false
    t.text "sentiment_reason"
    t.index ["comment_id"], name: "index_facebook_comment_moderations_on_comment_id"
    t.index ["conversation_id"], name: "index_facebook_comment_moderations_on_conversation_id"
    t.index ["message_id"], name: "index_facebook_comment_moderations_on_message_id"
    t.index ["moderated_by_id"], name: "index_facebook_comment_moderations_on_moderated_by_id"
    t.index ["moderation_type"], name: "index_facebook_comment_moderations_on_moderation_type"
    t.index ["status", "moderation_type"], name: "idx_on_status_moderation_type_4dd0516d2b"
    t.index ["status"], name: "index_facebook_comment_moderations_on_status"
  end

  create_table "features", id: :uuid, default: nil, force: :cascade do |t|
    t.string "name", null: false
    t.string "key", null: false
    t.text "description"
    t.boolean "is_active"
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at"

    t.unique_constraint ["key"], name: "features_key_key"
  end

  create_table "inactivity_action_executions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "conversation_id", null: false
    t.uuid "agent_bot_id", null: false
    t.integer "action_index", null: false
    t.datetime "executed_at", null: false
    t.jsonb "action_config", default: {}
    t.string "action_type"
    t.text "message_sent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_bot_id"], name: "index_inactivity_action_executions_on_agent_bot_id"
    t.index ["conversation_id", "action_index"], name: "index_inactivity_executions_on_conv_and_action", unique: true
    t.index ["conversation_id"], name: "index_inactivity_action_executions_on_conversation_id"
    t.index ["executed_at"], name: "index_inactivity_action_executions_on_executed_at"
  end

  create_table "inbox_members", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "inbox_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["inbox_id", "user_id"], name: "index_inbox_members_on_inbox_id_and_user_id", unique: true
    t.index ["inbox_id"], name: "index_inbox_members_on_inbox_id"
  end

  create_table "inboxes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "channel_id", null: false
    t.string "name", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "channel_type"
    t.boolean "enable_auto_assignment", default: true
    t.boolean "greeting_enabled", default: false
    t.string "greeting_message"
    t.string "email_address"
    t.boolean "working_hours_enabled", default: false
    t.string "out_of_office_message"
    t.string "timezone", default: "UTC"
    t.boolean "enable_email_collect", default: true
    t.boolean "csat_survey_enabled", default: false
    t.boolean "allow_messages_after_resolved", default: true
    t.jsonb "auto_assignment_config", default: {}
    t.boolean "lock_to_single_conversation", default: false, null: false
    t.jsonb "csat_config", default: {}
    t.integer "sender_name_type", default: 0, null: false
    t.string "business_name"
    t.string "display_name"
    t.string "default_conversation_status"
    t.index ["channel_id", "channel_type"], name: "index_inboxes_on_channel_id_and_channel_type"
    t.index ["default_conversation_status"], name: "index_inboxes_on_default_conversation_status"
  end

  create_table "installation_configs", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.jsonb "serialized_value", default: {}, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "locked", default: true, null: false
    t.index ["name", "created_at"], name: "index_installation_configs_on_name_and_created_at", unique: true
    t.index ["name"], name: "index_installation_configs_on_name", unique: true
  end

  create_table "integrations_hooks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.integer "status", default: 1
    t.uuid "inbox_id"
    t.string "app_id"
    t.integer "hook_type", default: 0
    t.string "reference_id"
    t.string "access_token"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "settings", default: {}
  end

  create_table "labels", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "title"
    t.text "description"
    t.string "color", default: "#1f93ff", null: false
    t.boolean "show_on_sidebar"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["title"], name: "index_labels_on_title", unique: true
  end

  create_table "macros", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.integer "visibility", default: 0
    t.uuid "created_by_id"
    t.uuid "updated_by_id"
    t.jsonb "actions", default: {}, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "mentions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "conversation_id", null: false
    t.datetime "mentioned_at", precision: nil, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["conversation_id"], name: "index_mentions_on_conversation_id"
    t.index ["user_id", "conversation_id"], name: "index_mentions_on_user_id_and_conversation_id", unique: true
    t.index ["user_id"], name: "index_mentions_on_user_id"
  end

  create_table "message_templates", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "channel_type", null: false
    t.uuid "channel_id", null: false
    t.string "name", null: false
    t.text "content", null: false
    t.string "language", default: "pt_BR"
    t.string "category"
    t.string "template_type"
    t.jsonb "components", default: {}
    t.jsonb "variables", default: []
    t.string "media_url"
    t.string "media_type"
    t.jsonb "settings", default: {}
    t.jsonb "metadata", default: {}
    t.boolean "active", default: true
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "idx_templates_by_category"
    t.index ["channel_type", "channel_id", "active"], name: "idx_templates_active_by_channel"
    t.index ["channel_type", "channel_id"], name: "index_message_templates_on_channel"
    t.index ["name", "channel_type", "channel_id"], name: "idx_templates_lookup"
    t.index ["name"], name: "idx_templates_by_name"
    t.index ["template_type"], name: "idx_templates_by_type"
  end

  create_table "messages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "content"
    t.uuid "inbox_id", null: false
    t.uuid "conversation_id", null: false
    t.integer "message_type", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "private", default: false, null: false
    t.integer "status", default: 0
    t.string "source_id"
    t.integer "content_type", default: 0, null: false
    t.json "content_attributes", default: {}
    t.string "sender_type"
    t.uuid "sender_id"
    t.jsonb "external_source_ids", default: {}
    t.jsonb "additional_attributes", default: {}
    t.text "processed_message_content"
    t.float "sentiment_score", default: 0.0
    t.integer "sentiment", default: 0, null: false
    t.index ["content"], name: "index_messages_on_content", opclass: :gin_trgm_ops, using: :gin
    t.index ["conversation_id", "created_at"], name: "idx_messages_conv_created_desc", order: { created_at: :desc }
    t.index ["conversation_id", "created_at"], name: "idx_messages_conv_created_incoming_desc", order: { created_at: :desc }, where: "(message_type = 0)"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["created_at"], name: "index_messages_on_created_at"
    t.index ["inbox_id", "content_type", "created_at"], name: "index_messages_for_type_date_inbox"
    t.index ["inbox_id"], name: "index_messages_on_inbox_id"
    t.index ["sender_type", "sender_id"], name: "index_messages_on_sender_type_and_sender_id"
    t.index ["source_id"], name: "index_messages_on_source_id"
  end

  create_table "notes", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.text "content", null: false
    t.uuid "contact_id", null: false
    t.uuid "user_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["contact_id"], name: "index_notes_on_contact_id"
    t.index ["user_id"], name: "index_notes_on_user_id"
  end

  create_table "notification_settings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id"
    t.integer "email_flags", default: 0, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "push_flags", default: 0, null: false
    t.index ["user_id"], name: "by_user", unique: true
  end

  create_table "notification_subscriptions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.integer "subscription_type", null: false
    t.jsonb "subscription_attributes", default: {}, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "identifier"
    t.index ["identifier"], name: "index_notification_subscriptions_on_identifier", unique: true
    t.index ["user_id"], name: "index_notification_subscriptions_on_user_id"
  end

  create_table "notifications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.integer "notification_type", null: false
    t.string "primary_actor_type", null: false
    t.uuid "primary_actor_id", null: false
    t.string "secondary_actor_type"
    t.uuid "secondary_actor_id"
    t.datetime "read_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "snoozed_until", precision: nil
    t.jsonb "meta", default: {}
    t.datetime "last_activity_at", precision: nil
    t.index ["primary_actor_type", "primary_actor_id"], name: "uniq_primary_actor_per_account_notifications"
    t.index ["secondary_actor_type", "secondary_actor_id"], name: "uniq_secondary_actor_per_account_notifications"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "oauth_access_grants", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "resource_owner_id", null: false
    t.uuid "application_id", null: false
    t.string "token", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "resource_owner_id"
    t.uuid "application_id", null: false
    t.string "token", null: false
    t.string "refresh_token"
    t.integer "expires_in"
    t.string "scopes"
    t.datetime "created_at", null: false
    t.datetime "revoked_at"
    t.string "previous_refresh_token", default: "", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.string "uid", null: false
    t.string "secret", null: false
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.boolean "confidential", default: true, null: false
    t.boolean "trusted", default: false, null: false
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "pipeline_items", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "pipeline_id", null: false
    t.uuid "conversation_id"
    t.uuid "pipeline_stage_id", null: false
    t.uuid "assigned_by_id"
    t.jsonb "custom_fields", default: {}
    t.datetime "entered_at", precision: nil, default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "completed_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.uuid "contact_id"
    t.index ["contact_id", "pipeline_id"], name: "index_pipeline_items_on_contact_id_and_pipeline_id", unique: true, where: "(conversation_id IS NULL)"
    t.index ["contact_id"], name: "index_pipeline_items_on_contact_id"
    t.index ["conversation_id", "pipeline_id"], name: "index_pipeline_items_on_conversation_id_and_pipeline_id", unique: true, where: "(conversation_id IS NOT NULL)"
    t.index ["custom_fields"], name: "index_pipeline_items_on_custom_fields", using: :gin
    t.index ["pipeline_id"], name: "index_pipeline_items_on_pipeline_id"
    t.index ["pipeline_stage_id"], name: "index_pipeline_items_on_pipeline_stage_id"
  end

  create_table "pipeline_service_definitions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "pipeline_id", null: false
    t.string "name", limit: 255, null: false
    t.decimal "default_value", precision: 10, scale: 2, default: "0.0", null: false
    t.string "currency", limit: 3, default: "BRL"
    t.text "description"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_pipeline_service_definitions_on_active"
    t.index ["pipeline_id", "name"], name: "index_pipeline_service_definitions_on_pipeline_and_name", unique: true
    t.index ["pipeline_id"], name: "index_pipeline_service_definitions_on_pipeline_id"
  end

  create_table "pipeline_stages", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "pipeline_id", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.string "color", default: "#3B82F6"
    t.integer "stage_type", default: 0
    t.jsonb "automation_rules", default: {}
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "custom_fields", default: {}, null: false
    t.index ["custom_fields"], name: "index_pipeline_stages_on_custom_fields", using: :gin
    t.index ["pipeline_id", "position"], name: "index_pipeline_stages_on_pipeline_id_and_position", unique: true
    t.index ["pipeline_id"], name: "index_pipeline_stages_on_pipeline_id"
  end

  create_table "pipeline_tasks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "pipeline_item_id", null: false
    t.uuid "created_by_id", null: false
    t.uuid "assigned_to_id"
    t.string "title", limit: 255, null: false
    t.text "description"
    t.datetime "due_date"
    t.integer "task_type", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.integer "priority", default: 0, null: false
    t.datetime "completed_at"
    t.jsonb "metadata", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "parent_task_id"
    t.integer "position", default: 0, null: false
    t.integer "depth", default: 0, null: false
    t.index ["assigned_to_id", "status", "due_date"], name: "index_pipeline_tasks_on_assigned_to_id_and_status_and_due_date"
    t.index ["assigned_to_id"], name: "index_pipeline_tasks_on_assigned_to_id"
    t.index ["created_by_id"], name: "index_pipeline_tasks_on_created_by_id"
    t.index ["due_date"], name: "index_pipeline_tasks_on_due_date"
    t.index ["parent_task_id", "position"], name: "index_pipeline_tasks_on_parent_task_id_and_position"
    t.index ["parent_task_id"], name: "index_pipeline_tasks_on_parent_task_id"
    t.index ["pipeline_item_id", "parent_task_id"], name: "index_pipeline_tasks_on_pipeline_item_id_and_parent_task_id"
    t.index ["pipeline_item_id", "status"], name: "index_pipeline_tasks_on_pipeline_item_id_and_status"
    t.index ["pipeline_item_id"], name: "index_pipeline_tasks_on_pipeline_item_id"
    t.index ["status", "due_date"], name: "index_pipeline_tasks_on_pending_status_and_due_date", where: "(status = 0)"
  end

  create_table "pipelines", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "created_by_id", null: false
    t.string "name", null: false
    t.text "description"
    t.string "pipeline_type", default: "custom", null: false
    t.integer "visibility", default: 0
    t.jsonb "config", default: {}
    t.boolean "is_active", default: true, null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.jsonb "custom_fields", default: {}, null: false
    t.boolean "is_default", default: false, null: false
    t.index ["created_by_id"], name: "index_pipelines_on_created_by_id"
    t.index ["custom_fields"], name: "index_pipelines_on_custom_fields", using: :gin
    t.index ["is_default"], name: "index_pipelines_on_is_default_unique", where: "(is_default = true)"
    t.index ["name"], name: "index_pipelines_on_name", unique: true
  end

  create_table "plan_features", id: :uuid, default: nil, force: :cascade do |t|
    t.uuid "plan_id", null: false
    t.uuid "feature_id", null: false
    t.string "value", null: false
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at"
  end

  create_table "plans", id: :uuid, default: nil, force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.boolean "is_active"
    t.timestamptz "created_at", default: -> { "now()" }
    t.timestamptz "updated_at"

    t.unique_constraint ["name"], name: "plans_name_key"
  end

  create_table "reporting_events", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.float "value"
    t.uuid "inbox_id"
    t.uuid "user_id"
    t.uuid "conversation_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.float "value_in_business_hours"
    t.datetime "event_start_time", precision: nil
    t.datetime "event_end_time", precision: nil
    t.index ["conversation_id"], name: "index_reporting_events_on_conversation_id"
    t.index ["created_at"], name: "index_reporting_events_on_created_at"
    t.index ["inbox_id"], name: "index_reporting_events_on_inbox_id"
    t.index ["name"], name: "index_reporting_events_on_name"
    t.index ["user_id"], name: "index_reporting_events_on_user_id"
  end

  create_table "role_permissions_actions", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "role_id", null: false
    t.string "permission_key", limit: 100, null: false
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["permission_key"], name: "index_role_permissions_actions_on_permission_key"
    t.index ["role_id", "permission_key"], name: "index_role_perms_actions_unique", unique: true
    t.index ["role_id"], name: "index_role_permissions_actions_on_role_id"
  end

  create_table "roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "key", null: false
    t.string "name", null: false
    t.text "description"
    t.string "type", limit: 10, default: "user", null: false
    t.boolean "system", default: false, null: false
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["key"], name: "index_roles_on_key", unique: true
    t.index ["name"], name: "index_roles_on_name", unique: true
    t.index ["type", "name"], name: "index_roles_on_type_and_name", unique: true
    t.index ["type"], name: "index_roles_on_type"
  end

  create_table "runtime_configs", force: :cascade do |t|
    t.string "key", null: false
    t.text "value", default: "", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_runtime_configs_on_key", unique: true
  end

  create_table "scheduled_action_execution_logs", force: :cascade do |t|
    t.bigint "scheduled_action_id", null: false
    t.string "status", limit: 50, default: "completed", null: false
    t.text "result_message"
    t.jsonb "error_details", default: {}
    t.integer "retry_count", default: 0
    t.integer "execution_time_ms"
    t.text "execution_log"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_scheduled_action_execution_logs_on_created_at"
    t.index ["scheduled_action_id", "created_at"], name: "idx_exec_logs_action_created"
    t.index ["scheduled_action_id"], name: "index_scheduled_action_execution_logs_on_scheduled_action_id"
    t.index ["status"], name: "index_scheduled_action_execution_logs_on_status"
  end

  create_table "scheduled_action_notifications", force: :cascade do |t|
    t.bigint "scheduled_action_id", null: false
    t.uuid "user_id", null: false
    t.string "notification_type", limit: 20, null: false
    t.string "status", limit: 20, default: "pending", null: false
    t.text "message"
    t.text "error_details"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["notification_type"], name: "index_scheduled_action_notifications_on_notification_type"
    t.index ["scheduled_action_id", "notification_type"], name: "idx_notifications_action_type"
    t.index ["scheduled_action_id"], name: "index_scheduled_action_notifications_on_scheduled_action_id"
    t.index ["status"], name: "index_scheduled_action_notifications_on_status"
    t.index ["user_id", "created_at"], name: "idx_notifications_user_date"
    t.index ["user_id"], name: "index_scheduled_action_notifications_on_user_id"
  end

  create_table "scheduled_action_templates", force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.string "action_type", limit: 50, null: false
    t.integer "default_delay_minutes"
    t.jsonb "payload", default: {}, null: false
    t.boolean "is_default", default: false
    t.boolean "is_public", default: false
    t.uuid "created_by", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["action_type"], name: "index_scheduled_action_templates_on_action_type"
    t.index ["is_default"], name: "idx_templates_default"
    t.index ["is_public"], name: "idx_templates_public"
  end

  create_table "scheduled_actions", force: :cascade do |t|
    t.bigint "deal_id"
    t.uuid "contact_id"
    t.uuid "conversation_id"
    t.string "action_type", limit: 50, null: false
    t.string "status", limit: 20, default: "scheduled", null: false
    t.datetime "scheduled_for", null: false
    t.datetime "executed_at"
    t.jsonb "payload", default: {}, null: false
    t.bigint "template_id"
    t.uuid "created_by", null: false
    t.integer "retry_count", default: 0
    t.integer "max_retries", default: 3
    t.text "error_message"
    t.string "recurrence_type", limit: 20
    t.jsonb "recurrence_config", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.uuid "notify_user_id"
    t.datetime "notification_sent_at"
    t.index ["action_type"], name: "index_scheduled_actions_on_action_type"
    t.index ["contact_id", "status"], name: "idx_scheduled_actions_contact_status"
    t.index ["contact_id"], name: "index_scheduled_actions_on_contact_id"
    t.index ["conversation_id"], name: "index_scheduled_actions_on_conversation_id"
    t.index ["deal_id", "status"], name: "idx_scheduled_actions_deal_status"
    t.index ["deal_id"], name: "index_scheduled_actions_on_deal_id"
    t.index ["notify_user_id"], name: "index_scheduled_actions_on_notify_user_id"
    t.index ["scheduled_for"], name: "index_scheduled_actions_on_scheduled_for"
    t.index ["status", "scheduled_for"], name: "idx_scheduled_actions_status_time"
    t.index ["status"], name: "index_scheduled_actions_on_status"
  end

  create_table "sessions", primary_key: ["app_name", "user_id", "id"], force: :cascade do |t|
    t.string "app_name", limit: 128, null: false
    t.string "user_id", limit: 128, null: false
    t.string "id", limit: 128, null: false
    t.jsonb "state", null: false
    t.datetime "create_time", precision: nil, null: false
    t.datetime "update_time", precision: nil, null: false
  end

  create_table "stage_movements", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "pipeline_item_id", null: false
    t.uuid "from_stage_id"
    t.uuid "to_stage_id", null: false
    t.uuid "moved_by_id"
    t.integer "movement_type", default: 0
    t.text "notes"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["pipeline_item_id"], name: "index_stage_movements_on_pipeline_item_id"
  end

  create_table "taggings", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "tag_id"
    t.string "taggable_type"
    t.uuid "taggable_id"
    t.string "tagger_type"
    t.uuid "tagger_id"
    t.string "context", limit: 128
    t.datetime "created_at", precision: nil
    t.index ["context"], name: "index_taggings_on_context"
    t.index ["tag_id", "taggable_id", "taggable_type", "context", "tagger_id", "tagger_type"], name: "taggings_idx", unique: true
    t.index ["tag_id"], name: "index_taggings_on_tag_id"
    t.index ["taggable_id", "taggable_type", "context"], name: "index_taggings_on_taggable_id_and_taggable_type_and_context"
    t.index ["taggable_id", "taggable_type", "tagger_id", "context"], name: "taggings_idy"
    t.index ["taggable_id"], name: "index_taggings_on_taggable_id"
    t.index ["taggable_type"], name: "index_taggings_on_taggable_type"
    t.index ["tagger_id", "tagger_type"], name: "index_taggings_on_tagger_id_and_tagger_type"
    t.index ["tagger_id"], name: "index_taggings_on_tagger_id"
  end

  create_table "tags", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.integer "taggings_count", default: 0
    t.index ["name"], name: "index_tags_on_name", unique: true
  end

  create_table "team_members", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "team_id", null: false
    t.uuid "user_id", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["team_id", "user_id"], name: "index_team_members_on_team_id_and_user_id", unique: true
    t.index ["team_id"], name: "index_team_members_on_team_id"
    t.index ["user_id"], name: "index_team_members_on_user_id"
  end

  create_table "teams", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name", null: false
    t.text "description"
    t.boolean "allow_auto_assign", default: true
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["name"], name: "index_teams_on_name", unique: true
  end

  create_table "telegram_bots", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "name"
    t.string "auth_key"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "user_roles", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "user_id", null: false
    t.uuid "role_id", null: false
    t.uuid "granted_by_id"
    t.datetime "granted_at", default: -> { "CURRENT_TIMESTAMP" }
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["granted_at"], name: "index_user_roles_on_granted_at"
    t.index ["granted_by_id"], name: "index_user_roles_on_granted_by_id"
    t.index ["role_id"], name: "index_user_roles_on_role_id"
    t.index ["user_id", "role_id"], name: "index_user_roles_unique", unique: true
    t.index ["user_id"], name: "index_user_roles_on_user_id"
  end

  create_table "user_states", primary_key: ["app_name", "user_id"], force: :cascade do |t|
    t.string "app_name", limit: 128, null: false
    t.string "user_id", limit: 128, null: false
    t.jsonb "state", null: false
    t.datetime "update_time", precision: nil, null: false
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "provider", default: "email", null: false
    t.string "uid", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.string "reset_password_token"
    t.datetime "reset_password_sent_at"
    t.datetime "remember_created_at"
    t.integer "sign_in_count", default: 0, null: false
    t.datetime "current_sign_in_at"
    t.datetime "last_sign_in_at"
    t.string "current_sign_in_ip"
    t.string "last_sign_in_ip"
    t.string "confirmation_token"
    t.datetime "confirmed_at"
    t.datetime "confirmation_sent_at"
    t.string "unconfirmed_email"
    t.string "name", null: false
    t.string "display_name"
    t.string "email"
    t.json "tokens"
    t.string "pubsub_token"
    t.integer "availability", default: 0
    t.jsonb "ui_settings", default: {}
    t.jsonb "custom_attributes", default: {}
    t.string "type"
    t.text "message_signature"
    t.string "otp_secret"
    t.boolean "otp_required_for_login", default: false, null: false
    t.integer "consumed_timestep"
    t.text "otp_backup_codes", default: [], array: true
    t.integer "mfa_method", default: 0, null: false
    t.string "email_otp_secret"
    t.datetime "email_otp_sent_at"
    t.integer "email_otp_attempts", default: 0
    t.datetime "mfa_confirmed_at"
    t.datetime "last_mfa_failure_at"
    t.integer "failed_mfa_attempts", default: 0
    t.datetime "created_at", default: -> { "now()" }, null: false
    t.datetime "updated_at", default: -> { "now()" }, null: false
    t.index ["email"], name: "index_users_on_email"
    t.index ["email_otp_sent_at"], name: "index_users_on_email_otp_sent_at"
    t.index ["mfa_method"], name: "index_users_on_mfa_method"
    t.index ["otp_required_for_login"], name: "index_users_on_otp_required_for_login"
    t.index ["pubsub_token"], name: "index_users_on_pubsub_token", unique: true
    t.index ["reset_password_token"], name: "index_users_on_reset_password_token", unique: true
    t.index ["uid", "provider"], name: "index_users_on_uid_and_provider", unique: true
  end

  create_table "webhooks", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "inbox_id"
    t.string "url"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "webhook_type", default: 0
    t.jsonb "subscriptions", default: ["conversation_status_changed", "conversation_updated", "conversation_created", "contact_created", "contact_updated", "message_created", "message_updated", "webwidget_triggered"]
    t.string "name"
    t.index ["url"], name: "index_webhooks_on_url", unique: true
  end

  create_table "working_hours", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.uuid "inbox_id"
    t.integer "day_of_week", null: false
    t.boolean "closed_all_day", default: false
    t.integer "open_hour"
    t.integer "open_minutes"
    t.integer "close_hour"
    t.integer "close_minutes"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "open_all_day", default: false
    t.index ["inbox_id"], name: "index_working_hours_on_inbox_id"
  end

  add_foreign_key "access_tokens", "users", column: "issued_id"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_bot_inboxes", "agent_bots", column: "facebook_comment_agent_bot_id", on_delete: :nullify
  add_foreign_key "contact_companies", "contacts"
  add_foreign_key "contact_companies", "contacts", column: "company_id"
  add_foreign_key "data_privacy_consents", "users"
  add_foreign_key "events", "sessions", column: ["app_name", "user_id", "session_id"], primary_key: ["app_name", "user_id", "id"], name: "events_app_name_user_id_session_id_fkey", on_delete: :cascade
  add_foreign_key "evo_agent_processor_execution_metrics", "evo_core_agents", column: "agent_id", name: "evo_agent_processor_execution_metrics_agent_id_fkey", on_delete: :cascade
  add_foreign_key "evo_ai_agent_processor_execution_metrics", "evo_core_agents", column: "agent_id", name: "evo_ai_agent_processor_execution_metrics_agent_id_fkey", on_delete: :cascade
  add_foreign_key "evo_core_agent_integrations", "evo_core_agents", column: "agent_id", name: "evo_core_agent_integrations_agent_id_fkey", on_delete: :cascade
  add_foreign_key "evo_core_agents", "evo_core_api_keys", column: "api_key_id", name: "evo_core_agents_api_key_id_fkey", on_delete: :nullify
  add_foreign_key "evo_core_agents", "evo_core_folders", column: "folder_id", name: "evo_core_agents_folder_id_fkey", on_delete: :nullify
  add_foreign_key "evo_core_folder_shares", "evo_core_folders", column: "folder_id", name: "evo_core_folder_shares_folder_id_fkey", on_delete: :cascade
  add_foreign_key "facebook_comment_moderations", "conversations"
  add_foreign_key "facebook_comment_moderations", "messages"
  add_foreign_key "facebook_comment_moderations", "users", column: "moderated_by_id"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "pipeline_items", "contacts"
  add_foreign_key "pipeline_items", "conversations"
  add_foreign_key "pipeline_items", "pipeline_stages"
  add_foreign_key "pipeline_items", "pipelines"
  add_foreign_key "pipeline_service_definitions", "pipelines"
  add_foreign_key "pipeline_tasks", "pipeline_items"
  add_foreign_key "pipeline_tasks", "pipeline_tasks", column: "parent_task_id"
  add_foreign_key "pipeline_tasks", "users", column: "assigned_to_id"
  add_foreign_key "pipeline_tasks", "users", column: "created_by_id"
  add_foreign_key "plan_features", "features", name: "plan_features_feature_id_fkey"
  add_foreign_key "plan_features", "plans", name: "plan_features_plan_id_fkey"
  add_foreign_key "role_permissions_actions", "roles"
  add_foreign_key "scheduled_action_execution_logs", "scheduled_actions"
  add_foreign_key "scheduled_action_notifications", "scheduled_actions", on_delete: :cascade
  add_foreign_key "scheduled_action_notifications", "users", on_delete: :cascade
  add_foreign_key "scheduled_action_templates", "users", column: "created_by", on_delete: :cascade
  add_foreign_key "scheduled_actions", "contacts", on_delete: :cascade
  add_foreign_key "scheduled_actions", "conversations", on_delete: :cascade
  add_foreign_key "scheduled_actions", "users", column: "created_by", on_delete: :cascade
  add_foreign_key "scheduled_actions", "users", column: "notify_user_id", on_delete: :nullify
  add_foreign_key "stage_movements", "pipeline_items"
  add_foreign_key "stage_movements", "pipeline_stages", column: "from_stage_id"
  add_foreign_key "stage_movements", "pipeline_stages", column: "to_stage_id"
  add_foreign_key "user_roles", "roles"
  add_foreign_key "user_roles", "users"
  add_foreign_key "user_roles", "users", column: "granted_by_id"
end
