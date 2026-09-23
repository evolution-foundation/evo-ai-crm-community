module Redis::RedisKeys
  ## Inbox Keys
  # Array storing the ordered ids for agent round robin assignment
  ROUND_ROBIN_AGENTS = 'ROUND_ROBIN_AGENTS:%<inbox_id>s'.freeze

  ## Conversation keys
  # Detect whether to send an email reply to the conversation
  CONVERSATION_MAILER_KEY = 'CONVERSATION::%<conversation_id>s'.freeze
  # Whether a conversation is muted ?
  CONVERSATION_MUTE_KEY = 'CONVERSATION::%<id>s::MUTED'.freeze
  CONVERSATION_DRAFT_MESSAGE = 'CONVERSATION::%<id>s::DRAFT_MESSAGE'.freeze

  ## User Keys
  # SSO Auth Tokens
  USER_SSO_AUTH_TOKEN = 'USER_SSO_AUTH_TOKEN::%<user_id>s::%<token>s'.freeze

  ## Online Status Keys
  # hash containing user_id key and status as value
  ONLINE_STATUS = 'ONLINE_STATUS'.freeze
  # sorted set storing online presence of contacts
  ONLINE_PRESENCE_CONTACTS = 'ONLINE_PRESENCE::CONTACTS'.freeze
  # sorted set storing online presence of users
  ONLINE_PRESENCE_USERS = 'ONLINE_PRESENCE::USERS'.freeze
  # global counters storing total messages by direction
  CRM_MESSAGES_TOTAL_INBOUND = 'CRM_MESSAGES_TOTAL::INBOUND'.freeze
  CRM_MESSAGES_TOTAL_OUTBOUND = 'CRM_MESSAGES_TOTAL::OUTBOUND'.freeze

  ## Authorization Status Keys
  # Used to track token expiry and such issues for facebook slack integrations etc
  AUTHORIZATION_ERROR_COUNT = 'AUTHORIZATION_ERROR_COUNT:%<obj_type>s:%<obj_id>s'.freeze
  REAUTHORIZATION_REQUIRED =  'REAUTHORIZATION_REQUIRED:%<obj_type>s:%<obj_id>s'.freeze

  ## Internal Installation related keys
  EVOLUTION_INSTALLATION_CONFIG_RESET_WARNING = 'EVOLUTION_CONFIG_RESET_WARNING'.freeze
  LATEST_EVOLUTION_VERSION = 'LATEST_EVOLUTION_VERSION'.freeze
  # Check if a message create with same source-id is in progress?
  MESSAGE_SOURCE_KEY = 'MESSAGE_SOURCE_KEY::%<id>s'.freeze
  # CRM-212: marks a conversation as eligible for a bot reply at the moment a
  # turn is dispatched, so delivery (which can arrive long after a label
  # changed mid-turn) has a grace window instead of re-deriving eligibility
  # from the conversation's current state.
  AGENT_BOT_TURN_ELIGIBLE_KEY = 'AGENT_BOT_TURN_ELIGIBLE::%<conversation_id>s'.freeze
  OPENAI_CONVERSATION_KEY = 'OPEN_AI_CONVERSATION_KEY::V1::%<event_name>s::%<conversation_id>s::%<updated_at>d'.freeze

  ## Sempahores / Locks
  # We don't want to process messages from the same sender concurrently to prevent creating double conversations
  FACEBOOK_MESSAGE_MUTEX = 'FB_MESSAGE_CREATE_LOCK::%<sender_id>s::%<recipient_id>s'.freeze
  FACEBOOK_COMMENT_MUTEX = 'FB_COMMENT_CREATE_LOCK::%<comment_id>s'.freeze
  FACEBOOK_POST_MUTEX = 'FB_POST_CREATE_LOCK::%<post_id>s'.freeze
  IG_MESSAGE_MUTEX = 'IG_MESSAGE_CREATE_LOCK::%<sender_id>s::%<ig_account_id>s'.freeze
  SLACK_MESSAGE_MUTEX = 'SLACK_MESSAGE_LOCK::%<conversation_id>s::%<reference_id>s'.freeze
  EMAIL_MESSAGE_MUTEX = 'EMAIL_CHANNEL_LOCK::%<inbox_id>s'.freeze
  CRM_PROCESS_MUTEX = 'CRM_PROCESS_MUTEX::%<hook_id>s'.freeze
end
