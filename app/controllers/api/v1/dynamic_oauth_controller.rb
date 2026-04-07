# frozen_string_literal: true

class Api::V1::DynamicOauthController < Api::V1::BaseController
  def available_accounts
    accounts = DynamicOauthService.available_accounts_for_user(current_user)

    render json: {
      success: true,
      data: {
        user_id: current_user.id,
        available_accounts: accounts,
        usage_example: {
          authorization_url: "#{request.base_url}/oauth/authorize",
          parameters: {
            response_type: 'code',
            client_id: '{dynamic_client_id}',
            redirect_uri: '{your_callback_url}',
            scope: 'admin',
            state: '{optional_state}'
          },
          example_url: accounts.first ?
            "#{request.base_url}/oauth/authorize?response_type=code&client_id=#{accounts.first[:dynamic_client_id]}&redirect_uri=https://your-app.com/callback&scope=admin&state=example" :
            nil
        }
      }
    }
  end

  def validate_dynamic_client
    client_id = params[:client_id]

    unless DynamicOauthService.is_dynamic_client_id?(client_id)
      return render json: {
        success: false,
        error: 'Invalid dynamic client ID format',
        expected_format: 'dynamic_app_{identifier}'
      }, status: :bad_request
    end

    render json: {
      success: true,
      data: {
        client_id: client_id,
        can_authorize: true
      }
    }
  end
end
