module Api
  module V1
    class FinancialTransactionsController < Api::V1::BaseController
      before_action :fetch_transaction, only: [:show, :update, :destroy, :confirm]

      def index
        @transactions = filtered_transactions
        render json: { success: true, data: FinancialTransactionSerializer.serialize_collection(@transactions) }
      end

      def show
        render json: { success: true, data: FinancialTransactionSerializer.serialize(@transaction) }
      end

      def create
        @transaction = FinancialTransaction.new(financial_transaction_params)
        if @transaction.save
          render json: { success: true, data: FinancialTransactionSerializer.serialize(@transaction) }, status: :created
        else
          render json: { success: false, errors: @transaction.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @transaction.update(financial_transaction_params)
          render json: { success: true, data: FinancialTransactionSerializer.serialize(@transaction) }
        else
          render json: { success: false, errors: @transaction.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @transaction.destroy
        render json: { success: true, message: 'Transaction deleted successfully' }
      end

      def confirm
        @transaction.confirm!
        render json: { success: true, data: FinancialTransactionSerializer.serialize(@transaction) }
      end

      private

      def fetch_transaction
        @transaction = FinancialTransaction.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, errors: ['Transaction not found'] }, status: :not_found
      end

      def filtered_transactions
        scope = FinancialTransaction.order(:transaction_date, :created_at).reverse_order
        # Pending (manual-accounting, not-yet-confirmed) occurrences are excluded from the
        # default listing — and therefore from every total/report computed from it — unless
        # explicitly requested via ?status=pending, which the "Pendentes de Confirmação" UI uses.
        scope = params[:status].present? ? scope.by_status(params[:status]) : scope.confirmed
        scope = scope.by_scope(params[:scope])
        scope = scope.by_kind(params[:kind])
        scope = scope.where('transaction_date >= ?', Date.parse(params[:from])) if params[:from].present?
        scope = scope.where('transaction_date <= ?', Date.parse(params[:to]).end_of_day) if params[:to].present?
        scope
      rescue ArgumentError, TypeError
        scope
      end

      def financial_transaction_params
        params.require(:financial_transaction).permit(:kind, :scope, :description, :category, :amount, :transaction_date, :receipt_url, :status)
      end
    end
  end
end