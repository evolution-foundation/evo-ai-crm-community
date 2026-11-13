# frozen_string_literal: true

require 'rails_helper'

# A request authenticated by an API access token is bounded by the token's
# scopes as well as by the user: the user may hold a permission the token was
# not given.
RSpec.describe EvoPermissionConcern do
  let(:harness) do
    Class.new do
      include EvoPermissionConcern
      include EvoAuthConcern
    end.new
  end

  let(:user) { instance_double(User, id: 'u1') }

  before do
    EvoExtensionPoints.reset!
    EvoExtensionPoints.replace(:permission_resolver) { |**| true }
    allow(EvoExtensionPoints::RuntimeContext).to receive(:current_scope_id).and_return(nil)
    Current.user = user
  end

  after do
    EvoExtensionPoints.reset!
    Current.reset
  end

  def authenticate_with(token_payload, method: 'api_access_token')
    Current.authentication_method = method
    Current.api_token_scopes = harness.send(:api_token_scopes_from, { 'token' => token_payload }, method)
  end

  it 'denies what the token scopes leave out, even when the user holds it' do
    authenticate_with({ 'scopes' => 'labels.read', 'effective_scopes' => %w[labels.read dashboard.read] })

    expect(harness.send(:has_user_permission?, 'u1', 'labels.read')).to be(true)
    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(false)
    expect(harness.send(:has_user_permission?, 'u1', 'labels.create')).to be(false)
  end

  it 'falls back to the listed scopes when the auth sends no effective scopes' do
    authenticate_with({ 'scopes' => 'contacts.read,contacts.create' })

    expect(harness.send(:has_user_permission?, 'u1', 'contacts.create')).to be(true)
    expect(harness.send(:has_user_permission?, 'u1', 'labels.read')).to be(false)
  end

  it 'leaves a default-scoped token bounded by the user alone' do
    authenticate_with({ 'scopes' => 'default' })

    expect(Current.api_token_scopes).to be_nil
    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(true)
  end

  it 'does not touch bearer sessions' do
    authenticate_with({ 'scopes' => 'labels.read' }, method: 'bearer')

    expect(harness.send(:has_user_permission?, 'u1', 'contacts.read')).to be(true)
  end

  it 'does not bound permission checks about another user' do
    authenticate_with({ 'scopes' => 'labels.read', 'effective_scopes' => %w[labels.read] })

    expect(harness.send(:has_user_permission?, 'u2', 'contacts.read')).to be(true)
  end
end
