class Integrations::Openai::ProcessorService < Integrations::OpenaiBaseService
  AGENT_INSTRUCTION = 'You are a helpful support agent.'.freeze
  def reply_suggestion_message
    return nil unless conversation

    make_api_call(reply_suggestion_body)
  end

  def summarize_message
    return nil unless conversation

    make_api_call(summarize_body)
  end

  def rephrase_message
    make_api_call(build_api_call_body(get_prompt('rephrase')))
  end

  def fix_spelling_grammar_message
    make_api_call(build_api_call_body(get_prompt('fix_spelling_grammar')))
  end

  def shorten_message
    make_api_call(build_api_call_body(get_prompt('shorten')))
  end

  def expand_message
    make_api_call(build_api_call_body(get_prompt('expand')))
  end

  def make_friendly_message
    make_api_call(build_api_call_body(get_prompt('make_friendly')))
  end

  def make_formal_message
    make_api_call(build_api_call_body(get_prompt('make_formal')))
  end

  def simplify_message
    make_api_call(build_api_call_body(get_prompt('simplify')))
  end

  def generate_prompt_message
    make_api_call(build_api_call_body(get_prompt('generate_prompt')))
  end

  def review_prompt_message
    make_api_call(build_api_call_body(get_prompt('review_prompt')))
  end

  private

  def prompt_from_file(file_name)
    # Use dynamic prompts from GlobalConfigService instead of files
    case file_name
    when 'summary'
      get_prompt('summary')
    when 'reply'
      get_prompt('reply')
    else
      # Fallback to file system for backward compatibility
      path = 'lib/integrations/openai/openai_prompts'
      Rails.root.join(path, "#{file_name}.txt").read
    end
  end

  def build_api_call_body(system_content, user_content = event['data']['content'])
    {
      model: gpt_model,
      messages: [
        { role: 'system', content: system_content },
        { role: 'user', content: user_content || '' }
      ]
    }.to_json
  end

  def conversation_messages(in_array_format: false)
    messages = init_messages_body(in_array_format)

    add_messages_until_token_limit(conversation, messages, in_array_format)
  end

  def add_messages_until_token_limit(conversation, messages, in_array_format, start_from = 0)
    character_count = start_from
    conversation.messages.where(message_type: [:incoming, :outgoing]).where(private: false).reorder('id desc').each do |message|
      character_count, message_added = add_message_if_within_limit(character_count, message, messages, in_array_format)
      break unless message_added
    end
    messages
  end

  def add_message_if_within_limit(character_count, message, messages, in_array_format)
    if valid_message?(message, character_count)
      add_message_to_list(message, messages, in_array_format)
      # Safety check for content length to prevent nil errors
      content_length = message.content&.length || 0
      character_count += content_length
      [character_count, true]
    else
      [character_count, false]
    end
  end

  def valid_message?(message, character_count)
    return false unless message.content.present?

    # Safety check for content length to prevent nil errors
    content_length = message.content&.length || 0
    character_count + content_length <= TOKEN_LIMIT
  end

  def add_message_to_list(message, messages, in_array_format)
    formatted_message = format_message(message, in_array_format)
    messages.prepend(formatted_message)
  end

  def init_messages_body(in_array_format)
    in_array_format ? [] : ''
  end

  def format_message(message, in_array_format)
    in_array_format ? format_message_in_array(message) : format_message_in_string(message)
  end

  def format_message_in_array(message)
    { role: (message.incoming? ? 'user' : 'assistant'), content: message.content || '' }
  end

  def format_message_in_string(message)
    sender_type = message.incoming? ? 'Customer' : 'Agent'
    "#{sender_type} #{message.sender&.name} : #{message.content || ''}\n"
  end

  def summarize_body
    system_prompt = prompt_from_file('summary')

    {
      model: gpt_model,
      messages: [
        { role: 'system',
          content: system_prompt },
        { role: 'user', content: conversation_messages }
      ]
    }.to_json
  end

  def reply_suggestion_body
    system_prompt = prompt_from_file('reply')

    {
      model: gpt_model,
      messages: [
        { role: 'system',
          content: system_prompt }
      ].concat(conversation_messages(in_array_format: true))
    }.to_json
  end
end

Integrations::Openai::ProcessorService.prepend_mod_with('Integrations::OpenaiProcessorService')
