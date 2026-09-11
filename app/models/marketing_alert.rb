# Aviso automático de Marketing (relatório semanal ou checagem diária de
# metas) — ver Marketing::AlertDispatcherService, que é quem cria estas
# linhas (só quando o canal "notification" está habilitado em
# MARKETING_ALERTS_CHANNELS).
class MarketingAlert < ApplicationRecord
  KINDS = %w[weekly_report daily_check].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :title, :body, presence: true

  scope :recent_first, -> { order(created_at: :desc) }
  scope :unread, -> { where(read_at: nil) }
end
