# frozen_string_literal: true

# Facebook Login user credentials are separate from Instagram Login messaging.
# Every eligible comment has its own reservation and encrypted receipt.
class Instagram::AmhCommentLike
  Result = Struct.new(:state, :reason, :receipt, keyword_init: true)
  API = 'https://graph.facebook.com/v26.0'
  REQUIRED_SCOPES = %w[instagram_basic instagram_manage_engagement].freeze

  def self.call(delivery:, explicit_test: false)
    return delivery unless reserve(delivery, explicit_test: explicit_test)

    result = request(delivery) { reserve_request(delivery, explicit_test: explicit_test) }
    receipt = result.receipt && Instagram::AmhInboundEvent.encryptor.encrypt_and_sign(result.receipt)
    delivery.update!(like_state: result.state, like_reason: result.reason, encrypted_like_receipt: receipt,
                     like_accepted_at: result.state == 'accepted' ? Time.current : nil)
    delivery
  end

  def self.eligible?(delivery, explicit_test:)
    proof = delivery.proof.reload
    Instagram::AmhExecutor.eligible!(delivery.inbound_event, proof, explicit_test: explicit_test)
    proof.active_version_id == delivery.version_id
  rescue Instagram::AmhExecutor::Unavailable
    false
  end

  def self.reserve(delivery, explicit_test:)
    delivery.with_lock do
      next false unless delivery.like_state == 'pending'

      reason = 'rule_unavailable' unless eligible?(delivery, explicit_test: explicit_test)
      reason ||= 'like_gate_disabled' unless ENV['INSTAGRAM_AMH_LIKES_ENABLED'] == 'true'
      if reason
        delivery.update!(like_state: 'blocked', like_reason: reason)
        next false
      end
      # Commit before the network. A crash leaves a reservation for reconciliation.
      delivery.update!(like_state: 'sending', like_reason: 'like_reserved')
      true
    end
  end

  def self.credentials
    token = ENV.fetch('INSTAGRAM_AMH_LIKES_FACEBOOK_USER_TOKEN', '')
    page = ENV.fetch('INSTAGRAM_AMH_LIKES_FACEBOOK_PAGE_ID', '')
    account = ENV.fetch('INSTAGRAM_AMH_LIKES_FACEBOOK_IG_USER_ID', '')
    return unless token.present? && [page, account].all? { |id| /\A[0-9]{1,64}\z/.match?(id) }

    [{ 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }, page, account]
  end

  def self.permissions?(headers)
    response = HTTParty.get("#{API}/me/permissions", headers: headers, timeout: 20)
    body = response.parsed_response
    return false unless response.success? && body.is_a?(Hash) && body['data'].is_a?(Array)

    scopes = body['data'].filter_map { |item| item['permission'] if item['status'] == 'granted' }
    (REQUIRED_SCOPES - scopes).empty?
  end

  def self.bound_account?(headers, page, account, channel)
    response = HTTParty.get("#{API}/#{page}", headers: headers,
                                              query: { fields: 'instagram_business_account{id}' }, timeout: 20)
    body = response.parsed_response
    response.success? && body.is_a?(Hash) && body.dig('instagram_business_account', 'id') == account &&
      account == ENV.fetch('INSTAGRAM_AMH_PROFESSIONAL_ACCOUNT_ID', '') && channel.instagram_id == account
  end

  def self.blocked(reason)
    Result.new(state: 'blocked', reason: reason)
  end

  def self.request(delivery)
    headers, page, account = credentials
    comment = delivery.inbound_event.contract['event_id'].to_s
    return blocked('facebook_connection_required') unless headers && /\A[0-9]{1,64}\z/.match?(comment)
    return blocked('engagement_permission_required') unless permissions?(headers)
    return blocked('facebook_account_mismatch') unless bound_account?(headers, page, account, Instagram::AmhConnection.bound_inbox!.channel)

    blocked_result = yield
    return blocked_result if blocked_result

    response = HTTParty.post("#{API}/#{account}/likes", headers: headers, body: JSON.generate(comment_id: comment), timeout: 20)
    result(response)
  rescue StandardError
    Result.new(state: 'uncertain', reason: 'transport_result_unknown')
  end

  def self.result(response)
    body = response.parsed_response
    if response.success? && body.is_a?(Hash) && body['success'] == true
      Result.new(state: 'accepted', reason: 'provider_accepted', receipt: { 'success' => true })
    elsif response.success? || response.code >= 500
      Result.new(state: 'uncertain', reason: 'provider_result_unknown')
    else
      receipt = body.is_a?(Hash) ? body.fetch('error', {}).slice('code', 'error_subcode', 'type', 'fbtrace_id') : {}
      Result.new(state: 'failed', reason: "provider_#{response.code}", receipt: receipt)
    end
  end

  def self.reserve_request(delivery, explicit_test:)
    Instagram::AmhVisualProof.with_mapping_lock do
      return blocked('rule_unavailable') unless eligible?(delivery, explicit_test: explicit_test)
      return blocked('like_gate_disabled') unless ENV['INSTAGRAM_AMH_LIKES_ENABLED'] == 'true'
      # Leave headroom below Meta's 50 requests / 5 seconds, across all workers.
      return blocked('like_rate_limited') if Instagram::AmhDelivery.where('like_requested_at > ?', 5.seconds.ago).count >= 40

      delivery.update!(like_requested_at: Time.current)
      nil
    end
  end
  private_class_method :reserve, :eligible?, :credentials, :permissions?, :bound_account?, :blocked, :request, :result, :reserve_request
end
