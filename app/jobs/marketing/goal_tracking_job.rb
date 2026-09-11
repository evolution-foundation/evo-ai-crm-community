module Marketing
  class GoalTrackingJob < ApplicationJob
    queue_as :low

    # Roda de madrugada calculando o dia ANTERIOR (ontem) — o dia corrente
    # ainda está incompleto, calcular "hoje" daria um custo por resultado
    # artificialmente alto/baixo dependendo da hora que o job roda.
    def perform(date: Date.yesterday)
      Marketing::GoalTrackingService.call(date: date)
      Marketing::DailyAlertService.call(date: date)
    end
  end
end
