# frozen_string_literal: true

module Dashboard
  class CustomerDashboardService
    WEEKDAY_LABELS = %w[Dom Seg Ter Qua Qui Sex Sab].freeze

    def initialize(account: nil, params:)
      @filters = Dashboard::FiltersBuilder.new(params: params)
    end

    def call
      {
        period: build_period,
        filters: @filters.applied_filters.except(:since, :until),
        stats: build_stats,
        csat: build_csat,
        ai_vs_human: build_ai_vs_human,
        follow_ups: build_follow_ups,
        pipeline: build_pipeline,
        channels: build_channels,
        agents: build_agents,
        ai_agents: build_ai_agents,
        trends: build_trends,
        capabilities: {
          has_recovery_metrics: false,
          has_ai_contribution_metrics: true,
          has_ai_vs_human_response_split: true
        }
      }
    end

    private

    def build_period
      {
        since: @filters.time_range.begin.to_i,
        until: @filters.time_range.end.to_i,
        days: ((@filters.time_range.end.to_date - @filters.time_range.begin.to_date).to_i + 1)
      }
    end

    def build_stats
      period_conversations = scoped_conversations
      current_operational_conversations = scoped_conversations_current
      events = scoped_reporting_events
      messages = scoped_messages

      {
        total_conversations: period_conversations.count,
        open_conversations: current_operational_conversations.open.count,
        pending_conversations: current_operational_conversations.pending.count,
        unattended_conversations: current_operational_conversations.open.unattended.count,
        unassigned_conversations: current_operational_conversations.open.unassigned.count,
        incoming_messages_count: messages.incoming.count,
        outgoing_messages_count: messages.outgoing.count,
        avg_first_response_time_seconds: average_event_value(events, 'first_response'),
        avg_resolution_time_seconds: average_event_value(events, 'conversation_resolved')
      }
    end

    def build_follow_ups
      tasks = scoped_pipeline_tasks.where(task_type: PipelineTask.task_types[:follow_up])

      {
        sent: tasks.completed.count,
        pending: tasks.pending.count,
        overdue: tasks.overdue.count
      }
    end

    def build_ai_vs_human
      outgoing_messages = scoped_messages.outgoing.where(private: false)
      ai_messages = outgoing_messages.where(sender_type: 'AgentBot')
      human_messages = outgoing_messages.human_outgoing
      ai_count = ai_messages.count
      human_count = human_messages.count
      total_known = ai_count + human_count

      ai_conversations = ai_messages.select(:conversation_id).distinct.count
      human_conversations = human_messages.select(:conversation_id).distinct.count

      ai_first_response, human_first_response = first_response_averages

      {
        ai_messages_count: ai_count,
        human_messages_count: human_count,
        ai_messages_share: percentage(ai_count, total_known),
        human_messages_share: percentage(human_count, total_known),
        ai_conversations_count: ai_conversations,
        human_conversations_count: human_conversations,
        avg_first_response_time_ai_seconds: ai_first_response,
        avg_first_response_time_human_seconds: human_first_response
      }
    end

    # A reply typed on the phone in an unassigned conversation leaves user_id null; it is
    # still a human reply, so it must not land in the AI average.
    def first_response_averages
      events = scoped_reporting_events.where(name: 'first_response')
      device_conversations = scoped_messages.reorder(nil).sent_from_device.select(:conversation_id)
      unattributed = events.where(user_id: nil)
      by_device = unattributed.where(conversation_id: device_conversations)

      [unattributed.where.not(conversation_id: device_conversations).average(:value).to_f.round(2),
       events.where.not(user_id: nil).or(by_device).average(:value).to_f.round(2)]
    end

    def build_csat
      responses = scoped_csat_responses
      total = responses.count
      avg_rating = responses.average(:rating).to_f.round(2)
      positive_count = responses.where(rating: 4..5).count
      negative_count = responses.where(rating: 1..2).count
      neutral_count = responses.where(rating: 3).count
      by_rating_hash = responses.group(:rating).count

      {
        total_responses: total,
        avg_rating: avg_rating,
        positive_rate: percentage(positive_count, total),
        negative_rate: percentage(negative_count, total),
        neutral_rate: percentage(neutral_count, total),
        rating_breakdown: (1..5).map do |rating|
          {
            rating: rating,
            count: by_rating_hash[rating].to_i,
            percentage: percentage(by_rating_hash[rating].to_i, total)
          }
        end
      }
    end

    def build_pipeline
      pipeline_items = scoped_pipeline_items.includes(:pipeline_stage)
      stages = pipeline_items.group_by(&:pipeline_stage).map do |stage, stage_items|
        {
          id: stage&.id,
          name: stage&.name || 'Sem estágio',
          count: stage_items.count,
          value: stage_items.sum(&:services_total_value).round(2)
        }
      end

      {
        total: pipeline_items.count,
        total_value: pipeline_items.sum(&:services_total_value).round(2),
        stages: stages.sort_by { |item| -item[:count] }
      }
    end

    def build_channels
      conversations = scoped_conversations
      total_conversations = conversations.count
      value_by_inbox_id = pipeline_value_by_inbox
      inboxes = Inbox.where(id: conversations.select(:inbox_id).distinct).index_by(&:id)

      conversations.group(:inbox_id).count.map do |inbox_id, count|
        {
          id: inbox_id,
          name: inboxes[inbox_id]&.name || 'Canal removido',
          conversations: count,
          percentage: percentage(count, total_conversations),
          value: value_by_inbox_id[inbox_id].to_f.round(2)
        }
      end.sort_by { |channel| -channel[:conversations] }
    end

    def build_agents
      conversations = scoped_conversations.where.not(assignee_id: nil)
      total_conversations = conversations.count
      conversations_by_agent = conversations.group(:assignee_id).count
      first_response_by_agent = scoped_reporting_events.where(name: 'first_response')
                                                      .where.not(user_id: nil)
                                                      .group(:user_id)
                                                      .average(:value)
      users = User.where(id: conversations_by_agent.keys).index_by(&:id)
      conversations_by_agent.map do |agent_id, count|
        user = users[agent_id]

        {
          id: agent_id,
          name: user&.available_name || user&.name || 'Agente removido',
          conversations: count,
          percentage: percentage(count, total_conversations),
          avg_first_response_time_seconds: first_response_by_agent[agent_id].to_f.round(2),
          availability_status: user&.availability_status || 'offline'
        }
      end.sort_by { |agent| -agent[:conversations] }
    end

    def build_ai_agents
      # Message has a default_scope ordering by created_at, which breaks grouped aggregates in PostgreSQL.
      bot_messages = scoped_messages.reorder(nil).outgoing.where(sender_type: 'AgentBot').where.not(sender_id: nil)
      total_bot_messages = bot_messages.count
      conversations_by_bot = bot_messages.group(:sender_id).pluck(:sender_id, Arel.sql('COUNT(DISTINCT conversation_id)')).to_h
      messages_by_bot = bot_messages.group(:sender_id).count
      bots = AgentBot.where(id: messages_by_bot.keys).index_by(&:id)

      messages_by_bot.map do |bot_id, count|
        bot = bots[bot_id]
        {
          id: bot_id,
          name: bot&.name || 'Agente IA removido',
          messages: count,
          conversations: conversations_by_bot[bot_id].to_i,
          percentage: percentage(count, total_bot_messages)
        }
      end.sort_by { |agent| -agent[:messages] }
    end

    def build_trends
      conversation_trend = scoped_conversations.group_by_day(:created_at, range: @filters.time_range, time_zone: 'UTC').count
      first_response_trend = scoped_reporting_events.where(name: 'first_response')
                                                   .group_by_day(:created_at, range: @filters.time_range, time_zone: 'UTC')
                                                   .average(:value)
      heatmap = build_operation_heatmap
      peak_period_day = conversation_trend.max_by { |_date, count| count.to_i }

      {
        conversations_daily: map_daily_metric(conversation_trend),
        response_time_daily: map_daily_metric(first_response_trend),
        operation_heatmap: heatmap,
        peak_day_in_period: {
          date: peak_period_day&.first&.strftime('%Y-%m-%d'),
          conversations: peak_period_day&.last.to_i
        }
      }
    end

    def build_operation_heatmap
      grouped = scoped_conversations
                .group(
                  Arel.sql("DATE(conversations.created_at AT TIME ZONE 'UTC')"),
                  Arel.sql("EXTRACT(HOUR FROM conversations.created_at AT TIME ZONE 'UTC')::int")
                )
                .count

      dates = (@filters.time_range.begin.to_date..@filters.time_range.end.to_date).to_a
      date_to_index = dates.each_with_index.to_h
      matrix = Array.new(dates.size) { Array.new(24, 0) }
      weekday_totals = Array.new(7, 0)
      hour_totals = Array.new(24, 0)

      grouped.each do |(date, hour), count|
        date_obj = date.is_a?(Date) ? date : Date.parse(date.to_s)
        next unless date_to_index.key?(date_obj)

        day_idx = date_to_index[date_obj]
        hour_idx = hour.to_i
        value = count.to_i
        matrix[day_idx][hour_idx] = value

        weekday_idx = date_obj.wday
        weekday_totals[weekday_idx] += value
        hour_totals[hour_idx] += value
      end

      days = dates.each_with_index.map do |date, idx|
        {
          day_index: idx,
          day_label: date.strftime('%d/%m'),
          date: date.strftime('%Y-%m-%d'),
          weekday_index: date.wday,
          weekday_label: WEEKDAY_LABELS[date.wday]
        }
      end

      cells = []
      max_value = 0
      peak_slot = { day_index: 0, day_label: days.first&.dig(:day_label), date: days.first&.dig(:date), hour: 0, conversations: 0 }

      days.each do |day|
        24.times do |hour|
          conversations = matrix[day[:day_index]][hour]
          max_value = [max_value, conversations].max

          if conversations > peak_slot[:conversations]
            peak_slot = {
              day_index: day[:day_index],
              day_label: day[:day_label],
              date: day[:date],
              hour: hour,
              conversations: conversations
            }
          end

          cells << {
            day_index: day[:day_index],
            day_label: day[:day_label],
            date: day[:date],
            hour: hour,
            conversations: conversations
          }
        end
      end

      weekday_summary = (0..6).map do |weekday|
        {
          day_index: weekday,
          day_label: WEEKDAY_LABELS[weekday],
          conversations: weekday_totals[weekday]
        }
      end

      hour_summary = 24.times.map { |hour| { hour: hour, conversations: hour_totals[hour] } }

      {
        timezone: 'UTC',
        days: days,
        hours: (0..23).to_a,
        cells: cells,
        max_value: max_value,
        peak_slot: peak_slot,
        peak_day_of_week: weekday_summary.max_by { |item| item[:conversations] } || weekday_summary.first,
        peak_hour: hour_summary.max_by { |item| item[:conversations] } || hour_summary.first
      }
    end

    def map_daily_metric(metric_hash)
      metric_hash.map do |date, value|
        {
          name: date.strftime('%d/%m'),
          value: value.to_f.round(2)
        }
      end
    end

    def pipeline_value_by_inbox
      values = Hash.new(0.0)

      scoped_pipeline_items.includes(:conversation).find_in_batches(batch_size: 1000) do |batch|
        batch.each do |item|
          next unless item.conversation&.inbox_id

          values[item.conversation.inbox_id] += item.services_total_value
        end
      end

      values
    end

    def average_event_value(events_scope, event_name)
      events_scope.where(name: event_name).average(:value).to_f.round(2)
    end

    def percentage(value, total)
      return 0 if total.zero?

      ((value.to_f / total) * 100).round(2)
    end

    def scoped_conversations
      @scoped_conversations ||= @filters.conversation_scope(Conversation.all)
    end

    def scoped_reporting_events
      @scoped_reporting_events ||= @filters.reporting_events_scope(ReportingEvent.all)
    end

    def scoped_conversations_current
      @scoped_conversations_current ||= @filters.conversation_scope(Conversation.all, apply_time_range: false)
    end

    def scoped_pipeline_items
      @scoped_pipeline_items ||= @filters.pipeline_items_scope(PipelineItem.all)
    end

    def scoped_pipeline_tasks
      @scoped_pipeline_tasks ||= @filters.pipeline_tasks_scope(PipelineTask.all)
    end

    def scoped_messages
      @scoped_messages ||= @filters.messages_scope(Message.all)
    end

    def scoped_csat_responses
      @scoped_csat_responses ||= @filters.csat_scope(CsatSurveyResponse.all)
    end
  end
end
