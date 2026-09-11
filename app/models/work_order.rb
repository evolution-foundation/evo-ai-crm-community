# == Schema Information
#
# Table name: work_orders
#
#  id                  :uuid             not null, primary key
#  base_value          :decimal(10, 2)   default(0.0), not null
#  checklist           :text
#  client_address      :string(255)
#  client_birthdate    :date
#  client_cep          :string(20)
#  client_city         :string(100)
#  client_cpf          :string(20)
#  client_email        :string(255)
#  client_gender       :string(20)
#  client_instagram    :string(255)
#  client_name         :string(255)
#  client_neighborhood :string(100)
#  client_number       :string(20)
#  client_phone        :string(40)
#  client_state        :string(20)
#  device              :string(255)
#  device_password     :string(100)
#  device_turns_on     :boolean          default(TRUE), not null
#  discount            :decimal(10, 2)   default(0.0), not null
#  entry_date          :datetime
#  installments        :integer
#  items               :jsonb            not null
#  observation         :text
#  os_number           :string(50)       not null
#  payment_method      :string(40)       default("Não Definido"), not null
#  picked_up           :boolean          default(FALSE), not null
#  pickup_date         :date
#  problems            :text
#  status              :string(20)       default("open"), not null
#  total               :decimal(10, 2)   default(0.0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#
# Indexes
#
#  index_work_orders_on_client_name  (client_name)
#  index_work_orders_on_entry_date   (entry_date)
#  index_work_orders_on_items        (items) USING gin
#  index_work_orders_on_os_number    (os_number) UNIQUE
#  index_work_orders_on_status       (status)
#
class WorkOrder < ApplicationRecord
  STATUSES = %w[open in_progress waiting_parts done delivered cancelled].freeze
  PAYMENT_METHODS = ['Não Definido', 'Dinheiro', 'Cartão de Crédito', 'Cartão de Débito', 'PIX', 'Transferência'].freeze
  FULFILLMENT_TYPES = %w[pickup delivery].freeze
  # 'keeta' não tem integração nenhuma no CRM ainda — fica disponível pra
  # marcar/organizar, mas nenhuma chamada de API existe pra essa opção.
  DELIVERY_COURIERS = %w[motoboy_proprio ifood 99 keeta].freeze

  belongs_to :motoboy, optional: true
  has_one :financial_transaction, dependent: :destroy

  # Populado pelo Orders::FulfillmentFinanceService logo após a criação —
  # avisos de estoque insuficiente (não bloqueiam a ordem), pro controller
  # devolver na resposta da criação.
  attr_accessor :stock_warnings

  validates :os_number, presence: true, uniqueness: true
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :payment_method, presence: true, inclusion: { in: PAYMENT_METHODS }
  validates :fulfillment_type, presence: true, inclusion: { in: FULFILLMENT_TYPES }
  validates :delivery_courier, inclusion: { in: DELIVERY_COURIERS }, allow_blank: true
  validates :base_value, numericality: { greater_than_or_equal_to: 0 }
  validates :discount, numericality: { greater_than_or_equal_to: 0 }
  validates :total, numericality: { greater_than_or_equal_to: 0 }

  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :by_payment_method, ->(method) { where(payment_method: method) if method.present? }
  scope :by_client, ->(term) do
    if term.present?
      normalized = term.to_s.strip
      where('client_name ILIKE :t OR client_cpf ILIKE :t OR client_phone ILIKE :t OR os_number ILIKE :t', t: "%#{normalized}%")
    end
  end
  scope :order_by_recent, -> { order(created_at: :desc) }

  after_create :sync_to_pipeline
  after_create :process_fulfillment
  after_update :sync_financial_transaction_amount, if: :saved_change_to_total?

  def items_count
    items.to_a.sum { |item| item['quantity'].to_i }
  end

  def item_names
    items.to_a.map { |item| item['name'] }.compact.join(', ')
  end

  # Gera o próximo número de OS incrementando o maior existente (padrão OS-XXXX)
  def self.next_os_number
    current = order(Arel.sql('os_number DESC')).limit(1).pluck(:os_number).first
    number = current.to_s[/\d+/]&.to_i || 0
    "OS-#{(number + 1).to_s.rjust(4, '0')}"
  end

  private

  # Ver Orders::PipelineSyncService — cria (ou não, se não configurado) um
  # card no pipeline/etapa escolhidos em Configurações > Ordens.
  def sync_to_pipeline
    Orders::PipelineSyncService.call(self)
  end

  # Ver Orders::FulfillmentFinanceService — abate estoque dos produtos
  # vendidos e lança a venda no financeiro da empresa. Só roda na criação:
  # editar uma ordem depois não deduz estoque de novo.
  def process_fulfillment
    result = Orders::FulfillmentFinanceService.call(self)
    self.stock_warnings = result.stock_warnings
  end

  # Mantém a receita lançada em dia com o total da ordem se ela for editada
  # depois (ex.: corrigir um valor) — não deduz/devolve estoque de novo.
  def sync_financial_transaction_amount
    return unless financial_transaction

    financial_transaction.update!(amount: total) if total.to_f > 0
  end
end
