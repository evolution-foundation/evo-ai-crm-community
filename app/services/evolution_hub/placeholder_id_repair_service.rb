# frozen_string_literal: true

# Repairs Hub-managed Instagram and Facebook channels still holding the placeholder platform id
# after the Hub finished connecting them. Report-only by default; `apply` writes. Only channels
# the Hub reports `active` with a real id are touched: one that never finished the Meta login
# has no real id to take, and must not be marked active.
module EvolutionHub
  class PlaceholderIdRepairService
    TARGETS = {
      ::Channel::Instagram => { attribute: :instagram_id, attrs_key: 'instagram_user_id' },
      ::Channel::FacebookPage => { attribute: :page_id, attrs_key: 'page_id' }
    }.freeze

    def self.call(...) = new(...).call

    def initialize(apply: false, io: $stdout, client: ::EvolutionHub::Client.new)
      @apply = apply
      @io = io
      @client = client
      @summary = { repaired: 0, would_repair: 0, hub_not_active: 0, no_real_id: 0, id_taken: 0, hub_error: 0, failed: 0 }
    end

    def call
      report_scope
      candidates = TARGETS.flat_map { |klass, target| placeholder_channels(klass, target[:attribute]).to_a }
      if candidates.empty?
        say 'no Hub channel holds a placeholder id, nothing to do.'
        return @summary
      end

      candidates.each { |channel| handle_one(channel) }
      say "done (#{apply ? 'applied' : 'dry run, nothing written'}): #{@summary.map { |k, v| "#{k}=#{v}" }.join(' ')}"
      @summary
    end

    private

    attr_reader :apply, :client

    # States what the run can see, so "nothing to do" is never mistaken for a scope that holds
    # nothing (a database role under row-level security sees no channel at all).
    def report_scope
      counts = TARGETS.keys.to_h { |klass| [klass.name, klass.count] }
      say "visible here: #{counts.map { |name, count| "#{count} #{name}" }.join(', ')}"
      say 'NOTE: this scope holds no Instagram or Facebook channel at all.' if counts.values.all?(&:zero?)
    end

    def placeholder_channels(klass, attribute)
      klass.where("#{klass.table_name}.#{attribute} LIKE ?", "#{ChannelReconciler::PENDING_ID_PREFIX}%")
           .where("evolution_hub_meta ->> 'channel_id' IS NOT NULL")
    end

    # One channel failing must not stop the others.
    def handle_one(channel)
      handle(channel)
    rescue StandardError => e
      skip(:failed, "#{label(channel)}: repair failed (#{e.class}: #{e.message.truncate(120)}), left as is")
    end

    def handle(channel)
      body = hub_channel(channel)
      return if body.nil?

      attrs = ChannelReconciler.attrs_from_hub_body(body)
      reason = skip_reason(channel, body, attrs)
      return skip(*reason) if reason

      apply ? repair(channel, attrs) : report_repair(channel, attrs)
    end

    def skip_reason(channel, body, attrs)
      attribute = TARGETS.fetch(channel.class)[:attribute]
      return [:hub_not_active, "#{label(channel)}: Hub status is #{body['status'].inspect}, left as is"] unless body['status'] == 'active'

      real_id = real_id_in(channel, attrs)
      return [:no_real_id, "#{label(channel)}: Hub has no real #{attribute} yet, left as is"] if real_id.blank?

      holder = ChannelReconciler.platform_id_holder(channel, attribute, real_id)
      [:id_taken, "#{label(channel)}: real #{attribute} already belongs to ##{holder}, left as is"] if holder
    end

    def report_repair(channel, attrs)
      @summary[:would_repair] += 1
      attribute = TARGETS.fetch(channel.class)[:attribute]
      say "#{label(channel)}: would replace #{channel[attribute]} with #{real_id_in(channel, attrs)} and mark it active"
    end

    # Same as a fresh channel_connected: a reauthorization flag left from before would keep
    # dropping the messages the repaired id now lets through.
    def repair(channel, attrs)
      ChannelReconciler.apply(channel, attrs)
      channel.reauthorized! if channel.respond_to?(:reauthorized!)
      attribute = TARGETS.fetch(channel.class)[:attribute]
      if ChannelReconciler.placeholder_id?(channel[attribute])
        return skip(:id_taken, "#{label(channel)}: the real #{attribute} was refused on write, kept the placeholder")
      end

      @summary[:repaired] += 1
      say "#{label(channel)}: #{attribute} is now #{channel[attribute]}, active"
    end

    def real_id_in(channel, attrs)
      attrs[TARGETS.fetch(channel.class)[:attrs_key]]
    end

    def label(channel)
      "#{channel.class.name}##{channel.id}"
    end

    def hub_channel(channel)
      resp = client.get_channel(ChannelReconciler.hub_channel_id_of(channel))
      resp.is_a?(Hash) ? (resp['channel'] || resp) : {}
    rescue StandardError => e
      skip(:hub_error, "#{label(channel)}: Hub lookup failed (#{e.class}), left as is")
      nil
    end

    def skip(reason, message)
      @summary[reason] += 1
      say message
      nil
    end

    def say(message)
      @io.puts "[evolution_hub_repair] #{message}"
    end
  end
end
