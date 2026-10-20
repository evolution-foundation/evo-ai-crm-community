# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Channels::ConnectionStateResolver do
  def resolve(channel)
    described_class.call(channel)
  end

  def stub_reauth(channel, value: false)
    allow(channel).to receive(:reauthorization_required?).and_return(value)
  end

  describe 'nil channel' do
    it 'degrades explicitly to unknown/none' do
      expect(resolve(nil)).to eq(state: 'unknown', source: 'none', last_sync: nil, reauthorization_required: false)
    end
  end

  describe 'Channel::Whatsapp' do
    it 'maps an open QR-provider connection to connected' do
      channel = Channel::Whatsapp.new(provider: 'evolution', provider_connection: { 'connection' => 'open' })
      stub_reauth(channel)

      result = resolve(channel)
      expect(result[:state]).to eq('connected')
      expect(result[:source]).to eq('provider_event')
    end

    it 'maps connecting to pending and close to disconnected' do
      connecting = Channel::Whatsapp.new(provider: 'baileys', provider_connection: { 'connection' => 'connecting' })
      closed = Channel::Whatsapp.new(provider: 'evolution_go', provider_connection: { 'connection' => 'close' })
      stub_reauth(connecting)
      stub_reauth(closed)

      expect(resolve(connecting)[:state]).to eq('pending')
      expect(resolve(closed)[:state]).to eq('disconnected')
    end

    it 'falls back to unknown when a QR provider has no connection event yet' do
      channel = Channel::Whatsapp.new(provider: 'evolution', provider_connection: {})
      stub_reauth(channel)

      expect(resolve(channel)[:state]).to eq('unknown')
    end

    it 'treats hub-managed channels by evolution_hub status' do
      channel = Channel::Whatsapp.new(provider: 'evolution',
                                      provider_config: { 'evolution_hub' => { 'status' => 'active' } })
      stub_reauth(channel)

      expect(resolve(channel)[:state]).to eq('connected')
    end

    it 'assumes token-based providers connected via stored_flag' do
      channel = Channel::Whatsapp.new(provider: 'whatsapp_cloud', provider_connection: {})
      stub_reauth(channel)

      result = resolve(channel)
      expect(result[:state]).to eq('connected')
      expect(result[:source]).to eq('stored_flag')
    end

    it 'overrides any state with error when reauthorization is required' do
      channel = Channel::Whatsapp.new(provider: 'evolution', provider_connection: { 'connection' => 'open' })
      stub_reauth(channel, value: true)

      result = resolve(channel)
      expect(result[:state]).to eq('error')
      expect(result[:reauthorization_required]).to be(true)
    end
  end

  describe 'Channel::Email' do
    it 'assumes connected via stored_flag, error when reauth required' do
      healthy = Channel::Email.new
      broken = Channel::Email.new
      stub_reauth(healthy)
      stub_reauth(broken, value: true)

      expect(resolve(healthy)).to include(state: 'connected', source: 'stored_flag')
      expect(resolve(broken)[:state]).to eq('error')
    end
  end

  describe 'Channel::Sendgrid' do
    it 'maps webhook_registration_status to states' do
      { 'active' => 'connected', 'pending' => 'pending', 'failed' => 'error', nil => 'unknown' }.each do |status, expected|
        channel = Channel::Sendgrid.new(webhook_registration_status: status)
        expect(resolve(channel)[:state]).to eq(expected), "status #{status.inspect}"
      end
    end
  end

  describe 'hub channels (FacebookPage / Instagram)' do
    it 'maps evolution_hub_meta status' do
      active = Channel::FacebookPage.new(evolution_hub_meta: { 'status' => 'active' })
      pending = Channel::Instagram.new(evolution_hub_meta: { 'status' => 'pending' })
      inactive = Channel::FacebookPage.new(evolution_hub_meta: { 'status' => 'inactive' })
      [active, pending, inactive].each { |c| stub_reauth(c) }

      expect(resolve(active)[:state]).to eq('connected')
      expect(resolve(pending)[:state]).to eq('pending')
      expect(resolve(inactive)[:state]).to eq('disconnected')
    end
  end

  describe 'direct Instagram OAuth' do
    let(:channel) do
      Channel::Instagram.new(instagram_id: '90001', access_token: 'inert-fixture', expires_at: 2.days.from_now)
    end

    before { stub_reauth(channel) }

    it 'reports configured credentials separately from a live provider event' do
      expect(channel).not_to receive(:access_token)
      expect(resolve(channel)).to include(state: 'connected', source: 'stored_flag')
    end

    it 'reports an expired token as an error' do
      channel.expires_at = 1.second.ago
      expect(resolve(channel)).to include(state: 'error', source: 'stored_flag')
    end

    it 'does not accept a token at its expiry boundary' do
      travel_to(Time.current.change(usec: 0)) do
        channel.expires_at = Time.current
        expect(resolve(channel)[:state]).to eq('error')
      end
    end

    it 'does not report missing credentials as connected' do
      channel[:access_token] = nil
      expect(resolve(channel)).to include(state: 'disconnected', source: 'stored_flag')
    end

    it 'does not report a missing account binding as connected' do
      channel[:instagram_id] = nil
      expect(resolve(channel)[:state]).to eq('disconnected')
    end

    it 'does not invent validity when expiry is missing' do
      channel.expires_at = nil
      expect(resolve(channel)).to include(state: 'unknown', source: 'none')
    end

    it 'keeps reauthorization as the strongest signal' do
      stub_reauth(channel, value: true)
      expect(resolve(channel)).to include(state: 'error', reauthorization_required: true)
    end

    it 'keeps Hub lifecycle authoritative even when credentials are present' do
      channel.evolution_hub_meta = { 'status' => 'pending' }
      expect(resolve(channel)).to include(state: 'pending', source: 'provider_event')
    end
  end

  describe 'channel types without health support' do
    it 'degrades explicitly to unknown/none' do
      channel = Channel::Telegram.new
      result = resolve(channel)

      expect(result[:state]).to eq('unknown')
      expect(result[:source]).to eq('none')
    end
  end

  describe 'last_sync' do
    it 'returns the channel updated_at' do
      timestamp = Time.zone.parse('2026-06-10 12:00:00')
      channel = Channel::Telegram.new(updated_at: timestamp)

      expect(resolve(channel)[:last_sync]).to eq(timestamp)
    end
  end
end
