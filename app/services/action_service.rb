class ActionService
  include EmailHelper

  def initialize(conversation)
    @conversation = conversation.reload
  end

  def mute_conversation(_params)
    @conversation.mute!
  end

  def snooze_conversation(_params)
    @conversation.snoozed!
  end

  def resolve_conversation(_params)
    @conversation.resolved!
  end

  def change_status(status)
    @conversation.update!(status: status[0])
  end

  def change_priority(priority)
    @conversation.update!(priority: (priority[0] == 'nil' ? nil : priority[0]))
  end

  def add_label(labels)
    return if labels.empty?

    @conversation.reload.add_labels(resolve_label_titles(labels))
  end

  def assign_agent(agent_ids = [])
    return @conversation.update!(assignee_id: nil) if agent_ids[0] == 'nil'

    return unless agent_belongs_to_inbox?(agent_ids)

    @agent = User.find_by(id: agent_ids)

    @conversation.update!(assignee_id: @agent.id) if @agent.present?
  end

  def remove_label(labels)
    return if labels.empty?

    targets = resolve_label_titles(labels)
    labels  = @conversation.label_list - targets
    @conversation.update!(label_list: labels)
  end

  def assign_team(team_ids = [])
    # FIXME: The explicit checks for zero or nil (string) is bad. Move
    # this to a separate unassign action.
    should_unassign = team_ids.blank? || %w[nil 0].include?(team_ids[0].to_s)
    return @conversation.update!(team_id: nil) if should_unassign

    # check if team belongs to account only if team_id is present
    # if team_id is nil, then it means that the team is being unassigned
    return unless !team_ids[0].nil? && team_belongs_to_account?(team_ids)

    @conversation.update!(team_id: team_ids[0])
  end

  def remove_assigned_team(_params)
    @conversation.update!(team_id: nil)
  end

  def send_email_transcript(emails)
    emails = emails[0].gsub(/\s+/, '').split(',')

    emails.each do |email|
      email = parse_email_variables(@conversation, email)
      ConversationReplyMailer.with(account: nil).conversation_transcript(@conversation, email)&.deliver_later
    end
  end

  private

  def agent_belongs_to_inbox?(agent_ids)
    member_ids = @conversation.inbox.members.pluck(:user_id)
    assignable_agent_ids = member_ids + User.where(type: 'SuperAdmin').pluck(:id)

    assignable_agent_ids.include?(agent_ids[0])
  end

  def team_belongs_to_account?(team_ids)
    Team.exists?(id: team_ids[0])
  end

  def conversation_a_tweet?
    return false if @conversation.additional_attributes.blank?

    @conversation.additional_attributes['type'] == 'tweet'
  end

  # Automation rules persist label_ids (UUIDs) in `action_params`, but
  # `acts_as_taggable_on :labels` stores tags by their **title** in
  # `tags.name`. Translate any UUIDs in the incoming array to their Label
  # title; values that aren't UUIDs (legacy rules that already stored titles)
  # are kept as-is so we don't break older configurations.
  UUID_LABEL_REGEX = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/.freeze

  def resolve_label_titles(values)
    values = Array(values).map(&:to_s).reject(&:empty?)
    return [] if values.empty?

    uuids, others = values.partition { |v| UUID_LABEL_REGEX.match?(v) }
    return others if uuids.empty?

    titles_by_id = Label.where(id: uuids).pluck(:id, :title).to_h.transform_keys(&:to_s)
    resolved     = uuids.filter_map { |id| titles_by_id[id] }

    (others + resolved).uniq
  end
  private :resolve_label_titles
end

ActionService.include_mod_with('ActionService')
