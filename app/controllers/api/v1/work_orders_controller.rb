module Api
  module V1
    class WorkOrdersController < Api::V1::BaseController
      before_action :fetch_work_order, only: [:show, :update, :destroy, :cancel]

      def index
        @work_orders = filtered_work_orders
        render json: { success: true, data: WorkOrderSerializer.serialize_collection(@work_orders) }
      end

      def show
        render json: { success: true, data: WorkOrderSerializer.serialize(@work_order) }
      end

      def create
        @work_order = WorkOrder.new(work_order_params)
        @work_order.os_number = WorkOrder.next_os_number if @work_order.os_number.blank?

        if @work_order.save
          render json: { success: true, data: WorkOrderSerializer.serialize(@work_order) }, status: :created
        else
          render json: { success: false, errors: @work_order.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def update
        if @work_order.update(work_order_params)
          render json: { success: true, data: WorkOrderSerializer.serialize(@work_order) }
        else
          render json: { success: false, errors: @work_order.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def destroy
        @work_order.destroy
        render json: { success: true, message: 'Work order deleted successfully' }
      end

      # PATCH /work_orders/:id/cancel — o operador escolhe na hora se quer
      # devolver os itens ao estoque e/ou estornar a venda do financeiro.
      def cancel
        result = Orders::CancellationService.call(
          @work_order,
          restore_stock: to_bool(params[:restore_stock]),
          reverse_financial: to_bool(params[:reverse_financial])
        )

        if result.success
          render json: { success: true, data: WorkOrderSerializer.serialize(@work_order.reload) }
        else
          render json: { success: false, errors: [result.error] }, status: :unprocessable_entity
        end
      end

      private

      def to_bool(value)
        ActiveModel::Type::Boolean.new.cast(value)
      end

      def fetch_work_order
        @work_order = WorkOrder.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { success: false, errors: ['Work order not found'] }, status: :not_found
      end

      def filtered_work_orders
        scope = WorkOrder.order_by_recent
        scope = scope.by_status(params[:status])
        scope = scope.by_payment_method(params[:payment_method])
        scope = scope.by_client(params[:q])
        if params[:from].present?
          scope = scope.where('entry_date >= ?', Date.parse(params[:from]).beginning_of_day)
        end
        if params[:to].present?
          scope = scope.where('entry_date <= ?', Date.parse(params[:to]).end_of_day)
        end
        scope
      rescue ArgumentError, TypeError
        WorkOrder.order_by_recent
      end

      def work_order_params
        params.require(:work_order).permit(
          :os_number, :status,
          :client_name, :client_cpf, :client_phone, :client_email, :client_instagram,
          :client_gender, :client_birthdate, :client_cep, :client_address, :client_number,
          :client_neighborhood, :client_city, :client_state,
          :device, :problems, :checklist, :observation, :device_password,
          :entry_date, :pickup_date, :device_turns_on, :picked_up,
          :fulfillment_type, :delivery_courier, :motoboy_id,
          :base_value, :discount, :total, :payment_method, :installments,
          items: [:product_id, :name, :sku, :tipo, :valor, :quantity]
        )
      end
    end
  end
end