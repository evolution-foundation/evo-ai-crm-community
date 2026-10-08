# frozen_string_literal: true

require 'rails_helper'

# A policy denial means "signed in, but not allowed": 403. Clients read 401 as a dead
# session and log the user out, so it stays reserved for authentication failures.
RSpec.describe RequestExceptionHandler do
  let(:json) { response.parsed_body }

  describe 'inside the API tree (Api::BaseController)' do
    controller(Api::BaseController) do
      def denied_with_record
        raise Pundit::NotAuthorizedError.new(query: 'show?', record: Pipeline.new, policy: nil)
      end

      def denied_with_class
        raise Pundit::NotAuthorizedError.new(query: 'create?', record: Pipeline, policy: nil)
      end

      def denied_bare
        raise Pundit::NotAuthorizedError
      end

      def not_found
        raise ActiveRecord::RecordNotFound.new('gone', 'Pipeline', 'id', 'missing')
      end

      def unauthenticated
        render_unauthorized('Authentication required')
      end
    end

    before do
      routes.draw do
        get 'denied_with_record' => 'api/base#denied_with_record'
        get 'denied_with_class' => 'api/base#denied_with_class'
        get 'denied_bare' => 'api/base#denied_bare'
        get 'not_found' => 'api/base#not_found'
        get 'unauthenticated' => 'api/base#unauthenticated'
      end
      allow(controller).to receive(:authenticate_request!)
    end

    it 'answers a policy denial with 403 FORBIDDEN and the denied action' do
      get :denied_with_record

      expect(response).to have_http_status(:forbidden)
      expect(json.dig('error', 'code')).to eq('FORBIDDEN')
      expect(json.dig('error', 'details')).to eq('action' => 'show?', 'record' => 'Pipeline')
    end

    it 'names the model when the policy was given the class' do
      get :denied_with_class

      expect(response).to have_http_status(:forbidden)
      expect(json.dig('error', 'details', 'record')).to eq('Pipeline')
    end

    it 'answers a bare denial with 403 and no invented details' do
      get :denied_bare

      expect(response).to have_http_status(:forbidden)
      expect(json.dig('error', 'code')).to eq('FORBIDDEN')
      expect(json['error']).not_to have_key('details')
    end

    it 'keeps a missing record at 404' do
      get :not_found

      expect(response).to have_http_status(:not_found)
    end

    it 'keeps an authentication failure at 401 UNAUTHORIZED' do
      get :unauthenticated

      expect(response).to have_http_status(:unauthorized)
      expect(json.dig('error', 'code')).to eq('UNAUTHORIZED')
    end
  end

  describe 'outside the API tree (ApplicationController)' do
    controller(ApplicationController) do
      def denied
        raise Pundit::NotAuthorizedError
      end
    end

    before do
      routes.draw { get 'denied' => 'anonymous#denied' }
    end

    it 'answers a policy denial with 403 too' do
      get :denied

      expect(response).to have_http_status(:forbidden)
      expect(json['error']).to eq('You are not authorized to perform this action')
    end
  end
end
