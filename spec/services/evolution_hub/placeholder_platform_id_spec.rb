# frozen_string_literal: true

require 'rails_helper'

# A Hub channel is created with a placeholder platform id (`pending_…`) because the real one only
# exists once the end user finishes the Meta login. Inbound events are matched by the real id, so
# a placeholder that survives channel_connected drops every message the channel receives.
RSpec.describe EvolutionHub::ChannelReconciler, 'placeholder platform ids' do
  let(:hub_channel_id) { "hub-#{SecureRandom.hex(4)}" }
  let(:real_ig_id) { "1784#{SecureRandom.random_number(10**10)}" }
  let(:real_page_id) { "1000#{SecureRandom.random_number(10**10)}" }

  before do
    allow(MetaBaseUrl).to receive(:enabled?).and_return(true)
    allow(Rails.configuration.dispatcher).to receive(:dispatch)
  end

  # Through the real builder, so a builder that stops minting the placeholder fails this spec.
  def pending_channel(channel_type, hub_id)
    builder = EvolutionHub::InboxBuilder.new(channel_type: channel_type, name: "Hub #{channel_type}")
    hub = instance_double(EvolutionHub::Client, create_channel: { 'channel' => { 'id' => hub_id }, 'webhook_id' => 'wh' })
    allow(builder).to receive(:hub_client).and_return(hub)
    builder.perform[:inbox].channel
  end

  def pending_instagram(hub_id = hub_channel_id)
    pending_channel('instagram', hub_id)
  end

  def pending_facebook(hub_id = hub_channel_id)
    pending_channel('facebook_page', hub_id)
  end

  # What row-level security does to a channel of another account: the holder lookup and the
  # uniqueness validation both miss it, and only the global unique index still sees it.
  def hide_other_accounts
    allow(EvolutionHub::ChannelReconciler).to receive(:platform_id_holder).and_return(nil)
    allow_any_instance_of(ActiveRecord::Validations::UniquenessValidator).to receive(:validate_each)
  end

  def connected(channel, connection)
    EvolutionHub::ChannelConnectedHandler.new(
      { 'external_id' => channel.id, 'channel_id' => hub_channel_id, 'channel_token' => 'hub-token' }.merge(connection)
    ).perform
    channel.reload
  end

  describe 'channel_connected' do
    it 'replaces the Instagram placeholder with the real id and activates the channel' do
      channel = connected(pending_instagram, 'instagram_connection' => { 'instagram_user_id' => real_ig_id })

      expect(channel.instagram_id).to eq(real_ig_id)
      expect(channel.evolution_hub_meta['status']).to eq('active')
    end

    it 'replaces the Facebook placeholder with the real page id and activates the channel' do
      channel = connected(pending_facebook, 'facebook_connection' => { 'page_id' => real_page_id, 'page_access_token' => 'pt' })

      expect(channel.read_attribute(:page_id)).to eq(real_page_id)
      expect(channel.evolution_hub_meta['status']).to eq('active')
    end

    it 'never overwrites a real id already on the channel' do
      channel = pending_instagram
      channel.update!(instagram_id: real_ig_id)

      channel = connected(channel, 'instagram_connection' => { 'instagram_user_id' => "#{real_ig_id}9" })

      expect(channel.instagram_id).to eq(real_ig_id)
    end

    it 'keeps the placeholder, still activates and logs when another channel holds the real id' do
      other = pending_instagram("hub-other-#{SecureRandom.hex(3)}")
      other.update!(instagram_id: real_ig_id)
      channel = pending_instagram
      placeholder = channel.instagram_id
      allow(Rails.logger).to receive(:error)

      channel = connected(channel, 'instagram_connection' => { 'instagram_user_id' => real_ig_id })

      expect(channel.instagram_id).to eq(placeholder)
      expect(channel.evolution_hub_meta['status']).to eq('active')
      expect(Rails.logger).to have_received(:error).with(a_string_including("belongs to Channel::Instagram##{other.id}"))
    end

    # Under row-level security the holder lookup cannot see another account's channel, while
    # the unique index is global: the write itself is what refuses the real id.
    it 'keeps the placeholder and still activates when the holder is invisible to this account' do
      other = pending_facebook("hub-other-#{SecureRandom.hex(3)}")
      other.update!(page_id: real_page_id)
      channel = pending_facebook
      placeholder = channel.read_attribute(:page_id)
      hide_other_accounts
      allow(Rails.logger).to receive(:error)

      # In production the handler runs inside the transaction that binds the account (joinable),
      # so a failed write without its own savepoint would abort everything after it.
      channel = ActiveRecord::Base.transaction do
        connected(channel, 'facebook_connection' => { 'page_id' => real_page_id, 'page_access_token' => 'pt' })
      end

      expect(channel.read_attribute(:page_id)).to eq(placeholder)
      expect(channel.evolution_hub_meta['status']).to eq('active')
      expect(Rails.logger).to have_received(:error).with(a_string_including('a channel this account cannot see'))
    end

    it 'falls back to the Hub for the real id when the payload carries none' do
      channel = pending_instagram
      client = instance_double(EvolutionHub::Client)
      allow(EvolutionHub::Client).to receive(:new).and_return(client)
      allow(client).to receive(:get_channel).with(hub_channel_id)
                                            .and_return('channel' => { 'instagram_connection' => { 'instagram_user_id' => real_ig_id } })

      channel = connected(channel, {})

      expect(channel.instagram_id).to eq(real_ig_id)
    end
  end

  describe 'ChannelReconciler' do
    it 'treats a blank or pending_ value as a placeholder and a real id as final' do
      expect(described_class.placeholder_id?(nil)).to be(true)
      expect(described_class.placeholder_id?('pending_ab12')).to be(true)
      expect(described_class.placeholder_id?(real_ig_id)).to be(false)
    end

    it 'repairs a channel that is already active with the placeholder' do
      channel = pending_instagram
      channel.update!(evolution_hub_meta: channel.evolution_hub_meta.merge('status' => 'active', 'channel_token' => 't'),
                      access_token: 'tok')

      described_class.apply(channel, { 'instagram_user_id' => real_ig_id })

      expect(channel.reload.instagram_id).to eq(real_ig_id)
    end

    it 'keeps the placeholder when the unique index refuses an id held by an invisible channel' do
      other = pending_instagram("hub-other-#{SecureRandom.hex(3)}")
      other.update!(instagram_id: real_ig_id)
      channel = pending_instagram
      placeholder = channel.instagram_id
      hide_other_accounts

      ActiveRecord::Base.transaction { described_class.apply(channel, { 'instagram_user_id' => real_ig_id }) }

      expect(channel.reload.instagram_id).to eq(placeholder)
      expect(channel.evolution_hub_meta['status']).to eq('active')
    end
  end

  describe 'PlaceholderIdRepairService' do
    let(:io) { StringIO.new }
    let(:client) { instance_double(EvolutionHub::Client) }

    def hub_body(status:, instagram: nil, facebook: nil)
      { 'channel' => { 'status' => status, 'token' => 'hub-token',
                       'instagram_connection' => instagram, 'facebook_connection' => facebook }.compact }
    end

    it 'only reports by default' do
      channel = pending_instagram
      allow(client).to receive(:get_channel).and_return(hub_body(status: 'active', instagram: { 'instagram_user_id' => real_ig_id }))

      summary = EvolutionHub::PlaceholderIdRepairService.call(io: io, client: client)

      expect(summary[:would_repair]).to eq(1)
      expect(channel.reload.instagram_id).to start_with('pending_')
    end

    it 'repairs the channels the Hub reports active with a real id' do
      instagram = pending_instagram
      facebook = pending_facebook("hub-fb-#{SecureRandom.hex(3)}")
      allow(client).to receive(:get_channel) do |id|
        if id == hub_channel_id
          hub_body(status: 'active', instagram: { 'instagram_user_id' => real_ig_id })
        else
          hub_body(status: 'active', facebook: { 'page_id' => real_page_id, 'page_access_token' => 'pt' })
        end
      end

      summary = EvolutionHub::PlaceholderIdRepairService.call(apply: true, io: io, client: client)

      expect(summary[:repaired]).to eq(2)
      expect(instagram.reload.instagram_id).to eq(real_ig_id)
      expect(facebook.reload.read_attribute(:page_id)).to eq(real_page_id)
      expect(facebook.evolution_hub_meta['status']).to eq('active')
    end

    it 'leaves alone a channel the Hub never finished connecting' do
      channel = pending_instagram
      allow(client).to receive(:get_channel).and_return(hub_body(status: 'inactive'))

      summary = EvolutionHub::PlaceholderIdRepairService.call(apply: true, io: io, client: client)

      expect(summary[:hub_not_active]).to eq(1)
      expect(channel.reload.instagram_id).to start_with('pending_')
      expect(channel.evolution_hub_meta['status']).to eq('pending')
    end

    it 'leaves alone a channel whose real id another channel already holds' do
      other = pending_instagram("hub-other-#{SecureRandom.hex(3)}")
      other.update!(instagram_id: real_ig_id)
      channel = pending_instagram
      allow(client).to receive(:get_channel).and_return(hub_body(status: 'active', instagram: { 'instagram_user_id' => real_ig_id }))

      summary = EvolutionHub::PlaceholderIdRepairService.call(apply: true, io: io, client: client)

      expect(summary[:id_taken]).to eq(1)
      expect(channel.reload.instagram_id).to start_with('pending_')
    end

    it 'keeps going when one channel fails to repair' do
      broken = pending_instagram
      fine = pending_instagram("hub-fine-#{SecureRandom.hex(3)}")
      allow(client).to receive(:get_channel) do |id|
        hub_body(status: 'active', instagram: { 'instagram_user_id' => id == hub_channel_id ? real_ig_id : "#{real_ig_id}7" })
      end
      allow(EvolutionHub::ChannelReconciler).to receive(:apply).and_call_original
      allow(EvolutionHub::ChannelReconciler).to receive(:apply).with(broken, anything).and_raise(ActiveRecord::StatementInvalid, 'boom')

      summary = EvolutionHub::PlaceholderIdRepairService.call(apply: true, io: io, client: client)

      expect(summary[:failed]).to eq(1)
      expect(summary[:repaired]).to eq(1)
      expect(fine.reload.instagram_id).to eq("#{real_ig_id}7")
      expect(broken.reload.instagram_id).to start_with('pending_')
    end
  end
end
