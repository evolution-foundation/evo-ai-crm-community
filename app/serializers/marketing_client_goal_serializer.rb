# frozen_string_literal: true

module MarketingClientGoalSerializer
  extend self

  OBJECTIVE_LABELS = {
    'mensagens' => 'Mensagens',
    'seguidores' => 'Seguidores',
    'video' => 'Visualizações de Vídeo',
    'alcance' => 'Alcance',
    'vendas_site' => 'Vendas no Site',
    'lead_site' => 'Lead no Site',
    'outro' => 'Outro'
  }.freeze

  def serialize(goal, detailed: false)
    {
      id: goal.id,
      name: goal.name,
      segments: goal.segments || [],
      sales_channel: goal.sales_channel,
      meta_budget: goal.meta_budget.to_f,
      active: goal.active,
      ad_accounts: (goal.ad_accounts || []).map { |acc| serialize_ad_account(goal, acc) },
      changelog: (goal.changelog || []).sort_by { |c| c['change_date'].to_s }.reverse,
      created_at: goal.created_at&.iso8601,
      updated_at: goal.updated_at&.iso8601
    }
  end

  def serialize_ad_account(goal, account)
    {
      id: account['id'],
      name: account['name'],
      locations: Array(account['locations']).map { |l| { name: l['name'], radius: l['radius'] } },
      age_min: account['age_min'],
      age_max: account['age_max'],
      gender: account['gender'],
      objectives: Array(account['objectives']).map { |o| serialize_objective(goal, o) }
    }
  end

  def serialize_objective(goal, objective)
    key = objective['key']
    streak = MarketingGoalDailyStatus.consecutive_out_of_margin_streak(marketing_client_goal_id: goal.id, objective_key: key)
    latest = MarketingGoalDailyStatus.for_objective(key).where(marketing_client_goal_id: goal.id).recent_first.first

    {
      key: key,
      objective_type: objective['objective_type'],
      label: objective['objective_type'] == 'outro' ? objective['custom_label'] : OBJECTIVE_LABELS[objective['objective_type']],
      budget: objective['budget'].to_f,
      target_result_daily: objective['target_result_daily'],
      target_result_weekly: objective['target_result_weekly'],
      target_result_monthly: objective['target_result_monthly'],
      cost_margin_daily_min: objective['cost_margin_daily_min'],
      cost_margin_daily_max: objective['cost_margin_daily_max'],
      cost_margin_weekly_min: objective['cost_margin_weekly_min'],
      cost_margin_weekly_max: objective['cost_margin_weekly_max'],
      cost_margin_monthly_min: objective['cost_margin_monthly_min'],
      cost_margin_monthly_max: objective['cost_margin_monthly_max'],
      status: {
        trackable: latest.present? && !latest.within_margin.nil?,
        last_date: latest&.date&.iso8601,
        last_cost_per_result: latest&.cost_per_result&.to_f,
        last_within_margin: latest&.within_margin,
        days_out_of_margin: streak,
        observation: build_observation(objective, latest, streak)
      }
    }
  end

  def build_observation(objective, latest, streak)
    return 'Acompanhamento automático não disponível para este objetivo.' if latest.nil? || latest.within_margin.nil?
    return "Dentro da meta (custo por resultado: R$ #{format('%.2f', latest.cost_per_result.to_f)})." if streak.zero?

    label = objective['objective_type'] == 'outro' ? objective['custom_label'] : OBJECTIVE_LABELS[objective['objective_type']]
    dia_plural = streak == 1 ? 'dia' : 'dias'
    "#{label}: #{streak} #{dia_plural} fora da meta (custo por resultado atual: R$ #{format('%.2f', latest.cost_per_result.to_f)})."
  end
end
