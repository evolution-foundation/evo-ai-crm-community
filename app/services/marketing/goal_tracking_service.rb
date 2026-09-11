# Roda diariamente (Marketing::GoalTrackingJob) pra cada conta de anúncio de
# cada MarketingClientGoal ativo: busca gasto/alcance/actions daquela conta
# num dia, calcula o custo por resultado de cada objetivo configurado PRA
# ELA (contas diferentes do mesmo cliente podem ter metas diferentes) e
# grava em MarketingGoalDailyStatus se ficou dentro ou fora da margem aceita
# naquele dia — a base do "N dias fora da meta".
#
# Objetivos sem uma `action_type` conhecida na Graph API (seguidores, outro)
# não têm como ser medidos automaticamente — a linha ainda é criada, mas
# com within_margin=nil (ver OBJECTIVE_ACTION_TYPES).
module Marketing
  class GoalTrackingService
    # action_type(s) do Meta Graph API Insights que representam o
    # "resultado" de cada tipo de objetivo. Uma lista porque a Graph API às
    # vezes reporta o mesmo evento sob nomes diferentes dependendo de como a
    # campanha foi configurada (pixel vs. Conversions API, por exemplo).
    OBJECTIVE_ACTION_TYPES = {
      'mensagens' => %w[onsite_conversion.total_messaging_connection onsite_conversion.messaging_conversation_started_7d],
      'video' => %w[video_view],
      'vendas_site' => %w[offsite_conversion.fb_pixel_purchase purchase omni_purchase],
      'lead_site' => %w[offsite_conversion.fb_pixel_lead lead onsite_conversion.lead_grouped],
      # Sem action_type nos Insights da Graph API — não dá pra automatizar.
      'seguidores' => [],
      'outro' => []
    }.freeze

    def self.call(date: Date.yesterday)
      new(date).call
    end

    def initialize(date)
      @date = date
      @service = Meta::AdsInsightsService.new
    end

    def call
      return unless @service.connected?

      MarketingClientGoal.active.find_each { |goal| process_goal(goal) }
    end

    private

    def process_goal(goal)
      Array(goal.ad_accounts).each { |account| process_account(goal, account) }
    end

    def process_account(goal, account)
      account_id = account['id']
      return if account_id.blank?

      objectives = Array(account['objectives'])
      return if objectives.empty?

      result = @service.account_insights_for_date(ad_account_id: account_id, date: @date)
      return unless result.success

      row = Array(result.data).first
      totals = insights_totals(row)

      objectives.each { |objective| upsert_daily_status(goal, objective, totals) }
    end

    def insights_totals(row)
      totals = { spend: 0.0, reach: 0, actions: Hash.new(0.0) }
      return totals unless row

      totals[:spend] = row['spend'].to_f
      totals[:reach] = row['reach'].to_i
      Array(row['actions']).each { |a| totals[:actions][a['action_type']] += a['value'].to_f }
      totals
    end

    def upsert_daily_status(goal, objective, totals)
      results, within_margin = compute_results_and_margin(objective, totals)

      status = MarketingGoalDailyStatus.find_or_initialize_by(
        marketing_client_goal_id: goal.id,
        objective_key: objective['key'],
        date: @date
      )
      status.spend = totals[:spend]
      status.results = results
      status.cost_per_result = results.positive? ? (totals[:spend] / results) : nil
      status.within_margin = within_margin
      status.save!
    end

    def compute_results_and_margin(objective, totals)
      type = objective['objective_type']

      results = if type == 'alcance'
                  totals[:reach] / 1000.0
                else
                  Array(OBJECTIVE_ACTION_TYPES[type]).sum { |action_type| totals[:actions][action_type] }
                end

      return [results, nil] if Array(OBJECTIVE_ACTION_TYPES[type]).empty? && type != 'alcance'
      return [results, nil] if results <= 0

      cost_per_result = totals[:spend] / results
      min = objective['cost_margin_daily_min'].to_f
      max = objective['cost_margin_daily_max'].to_f
      within_margin = if max.positive?
                         cost_per_result >= min && cost_per_result <= max
                       end
      [results, within_margin]
    end
  end
end
