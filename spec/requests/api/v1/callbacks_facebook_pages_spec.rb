# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Api::V1::CallbacksController, type: :controller do
  let(:user) { User.create!(email: 'fb-pages-spec@example.com', name: 'Fb Pages Spec') }
  let(:oauth) { double('Koala OAuth', exchange_access_token_info: { 'access_token' => 'long-lived' }) }
  let(:graph) { double('Koala API') }
  let(:accounts) { [{ 'id' => '111', 'name' => 'Page One', 'access_token' => 'page-token' }] }

  before do
    Current.user = user
    Current.service_authenticated = true
    Current.authentication_method = 'service_token'
    allow(controller).to receive(:authenticate_request!).and_return(true)
    allow(controller).to receive(:authorize).and_return(true)
    allow(controller).to receive(:pundit_user).and_return({ user: user, account_user: nil })
    allow(controller).to receive(:check_permission!).and_return(true)

    allow(Koala::Facebook::OAuth).to receive(:new).and_return(oauth)
    allow(Koala::Facebook::API).to receive(:new).and_return(graph)
    allow(graph).to receive(:get_connections).with('me', 'accounts').and_return(accounts)
  end

  after { Current.reset }

  describe 'POST facebook_pages' do
    it 'returns the pages for the exchanged long lived token' do
      post :facebook_pages, params: { omniauth_token: 'short-lived' }, format: :json

      expect(response).to have_http_status(:ok)
      expect(Koala::Facebook::API).to have_received(:new).with('long-lived')
    end

    # long_lived_token used to log the error and return the logger's return value (true) as the
    # "token", so a wrong FB_APP_ID or FB_APP_SECRET surfaced later as an empty page list.
    it 'fails loudly when the long lived token exchange fails' do
      allow(oauth).to receive(:exchange_access_token_info).and_raise(StandardError, 'bad app secret')

      post :facebook_pages, params: { omniauth_token: 'short-lived' }, format: :json

      expect(response).not_to have_http_status(:ok)
      expect(Koala::Facebook::API).not_to have_received(:new)
    end
  end
end
