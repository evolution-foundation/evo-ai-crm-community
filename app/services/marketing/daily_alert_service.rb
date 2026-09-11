# Roda logo depois de Marketing::GoalTrackingService (ver
# Marketing::GoalTrackingJob) — lê o status recém-calculado do dia e avisa
# (Marketing::AlertDispatcherService) se algum objetivo ficou fora da margem
# de custo aceita, ou confirma que está tudo dentro da meta.
module Marketing
  class DailyAlertService
    def self.call(date:)
      new(date).call
    end

    def initialize(date)
      @date = date
    end

    def call
      statuses = MarketingGoalDailyStatus.where(date: @date, marketing_client_goal: MarketingClientGoal.active)
                                          .includes(:marketing_client_goal)
      return if statuses.empty?

      out_of_margin = statuses.select { |s| s.within_margin == false }

      Marketing::AlertDispatcherService.call(
        kind: 'daily_check',
        title: "Checagem Diária de Metas — #{@date.strftime('%d/%m/%Y')}",
        body: build_body(out_of_margin)
      )
    end

    private

    def build_body(out_of_margin)
      return "Todas as contas de anúncio com meta cadastrada ficaram dentro da margem em #{@date.strftime('%d/%m/%Y')}." if out_of_margin.empty?

      lines = out_of_margin.map do |status|
        goal = status.marketing_client_goal
        cost = status.cost_per_result ? format('R$ %.2f', status.cost_per_result.to_f) : 'N/D'
        "- #{goal.name} — #{objective_label(goal, status.objective_key)}: fora da meta (custo por resultado: #{cost})"
      end

      "#{out_of_margin.size} objetivo(s) fora da meta em #{@date.strftime('%d/%m/%Y')}:\n\n#{lines.join("\n")}"
    end

    def objective_label(goal, objective_key)
      objective = Array(goal.ad_accounts).flat_map { |acc| Array(acc['objectives']) }.find { |o| o['key'] == objective_key }
      return objective_key if objective.nil?

      objective['objective_type'] == 'outro' ? objective['custom_label'] : objective['objective_type']
    end
  end
end
