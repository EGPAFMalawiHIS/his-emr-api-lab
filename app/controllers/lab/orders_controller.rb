# frozen_string_literal: true

module Lab
  class OrdersController < ApplicationController
    def create
      order_params_list = params.require(:orders)
      orders = order_params_list.map do |order_params|
        OrdersService.order_test(order_params)
      end

      orders.each { |order| Lab::PushOrderJob.perform_later(order.fetch(:order_id)) }

      render json: orders, status: :created
    end

    def update
      specimen = params.require(:specimen).slice(:concept_id)
      order = OrdersService.update_order(params[:id], specimen:, force_update: params[:force_update])
      Lab::PushOrderJob.perform_later(order.fetch(:order_id))

      render json: order
    end

    def index
      filters = params.slice(:patient_id, :accession_number, :date, :status)

      Lab::UpdatePatientOrdersJob.perform_later(filters[:patient_id]) if filters[:patient_id]
      render json: OrdersSearchService.find_orders(filters)
    end

    def verify_tracking_number
      tracking_number = params.require(:accession_number)
      render json: { exists: OrdersService.check_tracking_number(tracking_number) }, status: :ok
    end

    def destroy
      OrdersService.void_order(params[:id], params[:reason])
      Lab::VoidOrderJob.perform_later(params[:id])

      render status: :no_content
    end
  end
end
