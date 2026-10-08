module Api
  module V1
    module Admin
      class BaseController < Api::BaseController
        before_action :authorize_admin!

        private

        def authorize_admin!
          authorize :installation_config, :manage?
        end

        def handle_not_authorized(_exception)
          error_response(
            ApiErrorCodes::FORBIDDEN,
            'You are not authorized to perform this action',
            details: { action: 'manage', resource: 'installation_config' },
            status: :forbidden
          )
        end
      end
    end
  end
end
