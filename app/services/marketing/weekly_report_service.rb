# Roda toda segunda-feira (ver config/schedule.yml) — resume a semana
# anterior (segunda a domingo) de cada conta de anúncio com objetivo
# cadastrado em Metas de Clientes, usando os status diários já calculados
# por Marketing::GoalTrackingService, e manda pelos canais configurados em
# Marketing > Alertas e Relatórios (Marketing::AlertDispatcherService).
module Marketing
  class WeeklyReportService
    def self.call(reference_date: Date.yesterday)
      new(reference_date).call
    end

    def initialize(reference_date)
      @end_date = reference_date
      @start_date = @end_date - 6
    end

    def call
      goals = MarketingClientGoal.active.order(:name)
      return if goals.empty?

      Marketing::AlertDispatcherService.call(
        kind: 'weekly_report',
        title: "Relatório Semanal de Marketing (#{@start_date.strftime('%d/%m')} a #{@end_date.strftime('%d/%m')})",
        body: build_body(goals)
      )
    end

    private

    def build_body(goals)
      lines = []
      goals.each do |goal|
        Array(goal.ad_accounts).each do |account|
          objectives = Array(account['objectives'])
          next if objectives.empty?

          lines << "*#{goal.name} — #{account['name'].presence || account['id']}*"
          objectives.each { |objective| lines << objective_line(objective) }
          lines << ''
        end
      end

      lines.any? ? lines.join("\n").strip : 'Nenhum cliente com conta de anúncio e objetivo cadastrado.'
    end

    def objective_line(objective)
      label = objective['objective_type'] == 'outro' ? objective['custom_label'] : objective['objective_type']
      statuses = MarketingGoalDailyStatus.where(objective_key: objective['key'], date: @start_date..@end_date)
      return "- #{label}: sem dados de acompanhamento na semana." if statuses.empty?

      spend = statuses.sum { |s| s.spend.to_f }
      results = statuses.sum { |s| s.results.to_f }
      days_out = statuses.count { |s| s.within_margin == false }
      cost_per_result = results.positive? ? spend / results : nil
      cost_txt = cost_per_result ? format('R$ %.2f', cost_per_result) : 'N/D'

      "- #{label}: gasto R$ #{format('%.2f', spend)} | resultados #{results.to_i} | custo/resultado #{cost_txt} | #{days_out} dia(s) fora da meta"
    end
  end
end
