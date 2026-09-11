# frozen_string_literal: true

# Cancela uma WorkOrder (marca status: 'cancelled', mantém o registro pra
# histórico — diferente de excluir) com o operador escolhendo, na hora, se
# quer devolver os itens ao estoque e/ou estornar a venda do financeiro.
# Nenhuma das duas é automática: uma ordem pode ser cancelada por um motivo
# que não envolve devolver mercadoria (ex.: erro de cadastro) ou que não deve
# mexer no financeiro (ex.: já foi pago e não vai ser reembolsado).
class Orders::CancellationService
  Result = Struct.new(:success, :error, keyword_init: true)

  def self.call(work_order, restore_stock:, reverse_financial:)
    new(work_order, restore_stock: restore_stock, reverse_financial: reverse_financial).call
  end

  def initialize(work_order, restore_stock:, reverse_financial:)
    @work_order = work_order
    @restore_stock = restore_stock
    @reverse_financial = reverse_financial
  end

  def call
    ActiveRecord::Base.transaction do
      @work_order.update!(status: 'cancelled')
      restock_items! if @restore_stock
      reverse_financial_transaction! if @reverse_financial
    end
    Result.new(success: true)
  rescue StandardError => e
    Rails.logger.error "Orders::CancellationService: #{e.message}"
    Result.new(success: false, error: e.message)
  end

  private

  def restock_items!
    Array(@work_order.items).each do |item|
      product_id = item['product_id']
      next if product_id.blank?

      quantity = item['quantity'].to_i
      next if quantity <= 0

      product = Product.find_by(id: product_id)
      next if product.nil?

      product.restock!(quantity: quantity)
    end
  end

  def reverse_financial_transaction!
    @work_order.financial_transaction&.destroy
  end
end
