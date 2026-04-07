class Api::V1::ContactBulkTransfersController < Api::V1::BaseController
  require_permissions({
                        create: 'contacts.update'
                      })

  def create
    service_result = Contacts::BulkTransferService.new(
      contact_ids: bulk_transfer_params[:contact_ids],
      from_company_id: bulk_transfer_params[:from_company_id],
      to_company_id: bulk_transfer_params[:to_company_id]
    ).perform

    if service_result[:success]
      from_company = Contact.companies.find_by(id: bulk_transfer_params[:from_company_id])
      to_company = Contact.companies.find_by(id: bulk_transfer_params[:to_company_id])
      
      render json: {
        success: true,
        message: "#{service_result[:transferred_count]} contacts transferred successfully",
        transferred_count: service_result[:transferred_count],
        from_company: {
          id: from_company&.id,
          name: from_company&.name,
          type: 'company'
        },
        to_company: {
          id: to_company&.id,
          name: to_company&.name,
          type: 'company'
        }
      }, status: :ok
    else
      render json: { error: service_result[:error] }, status: :unprocessable_entity
    end
  end

  private

  def bulk_transfer_params
    params.require(:bulk_transfer).permit(:from_company_id, :to_company_id, contact_ids: [])
  end
end

