module Marketing
  class WeeklyReportJob < ApplicationJob
    queue_as :low

    def perform(reference_date: Date.yesterday)
      Marketing::WeeklyReportService.call(reference_date: reference_date)
    end
  end
end
