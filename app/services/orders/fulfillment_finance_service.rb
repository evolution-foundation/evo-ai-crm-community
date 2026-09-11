# frozen_string_literal: true

# Roda quando uma WorkOrder (Ordem) é criada: abate o estoque dos produtos
# vendidos (via Product#sell!, que já sabe deduzir tanto stock_quantity
# direto quanto ingredientes de receita) e registra a venda no financeiro da
# empresa (FinancialTransaction). Nunca trava a criação da ordem — problema
# de estoque insuficiente vira um aviso (`stock_warnings`) devolvido pro
# front, não um erro que impede a venda de ser registrada.
class Orders::FulfillmentFinanceService
  Result = Struct.new(:financial_transaction, :stock_warnings, keyword_init: true)

  def self.call(work_order)
    new(work_order).call
  end

  def initialize(work_order)
    @work_order = work_order
  end

  def call
    warnings = deduct_stock!
    transaction = register_financial_transaction!
    Result.new(financial_transaction: transaction, stock_warnings: warnings)
  rescue StandardError => e
    Rails.logger.error "Orders::FulfillmentFinanceService: #{e.message}"
    Result.new(financial_transaction: nil, stock_warnings: [])
  end

  private

  def deduct_stock!
    warnings = []

    Array(@work_order.items).each do |item|
      product_id = item['product_id']
      next if product_id.blank?

      quantity = item['quantity'].to_i
      next if quantity <= 0

      product = Product.find_by(id: product_id)
      next if product.nil?

      begin
        product.sell!(quantity: quantity)
      rescue Product::InsufficientStockError => e
        warnings << e.message
      end
    end

    warnings
  end

  # Idempotente (índice único em work_order_id) — se já existe uma
  # transação pra essa ordem (ex.: callback rodou mais de uma vez por algum
  # motivo), não duplica a receita.
  def register_financial_transaction!
    return @work_order.financial_transaction if @work_order.financial_transaction.present?
    return nil if @work_order.total.to_f <= 0

    FinancialTransaction.create!(
      work_order: @work_order,
      kind: 'income',
      scope: 'store',
      description: "Ordem #{@work_order.os_number}#{@work_order.client_name.present? ? " - #{@work_order.client_name}" : ''}",
      category: 'Vendas',
      amount: @work_order.total,
      transaction_date: @work_order.entry_date || Time.current,
      status: 'confirmed',
      confirmed_at: Time.current
    )
  rescue ActiveRecord::RecordNotUnique
    @work_order.reload.financial_transaction
  end
end
