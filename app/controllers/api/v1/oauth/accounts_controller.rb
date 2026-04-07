# frozen_string_literal: true

class Api::V1::Oauth::AccountsController < Api::BaseController
  before_action :authenticate_user!

  def index
    accounts = if current_user.administrator?
                 [{
                   account_name: GlobalConfigService.load('BRAND_NAME', 'Evo CRM'),
                   dynamic_client_id: DynamicOauthService.generate_dynamic_client_id('default')
                 }]
               else
                 []
               end

    success_response(data: accounts, message: 'OAuth accounts retrieved successfully')
  end
end