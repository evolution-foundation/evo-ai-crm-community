module EvoFlow
  # Backfills existing contact labels to evo-flow via /events/identify, so
  # the local `taggings` table evo-flow uses to resolve tag-filtered campaign
  # audiences (SegmentQueryBuilderService#getContactsByTags) is populated for
  # labels applied before the live publisher (ContactEventsListener) was
  # enabled — historically EVO_FLOW_ENABLED defaulted unset/false, so any
  # label applied prior to turning it on was never forwarded.
  #
  # Unlike BackfillContactEventsWorker this has no batch HTTP endpoint to
  # flush against: each row enqueues one EvoFlow::PublishEventWorker job via
  # '/events/identify', mirroring exactly what Contact#publish_label_added
  # does on the live path (same event name, same payload shape). That keeps
  # this worker a thin enumerator — all retry/redaction/error handling for
  # the actual HTTP call lives in PublishEventWorker already.
  #
  # retry: 2 (matches BackfillContactEventsWorker) — resumable via a Redis
  # cursor keyed on the taggings UUID primary key, so a hard failure loses at
  # most one Sidekiq queue attempt of forward progress, not the whole run.
  class BackfillContactLabelsWorker
    include Sidekiq::Worker
    sidekiq_options queue: :integrations, retry: 2

    SCAN_BATCH_SIZE = 1000
    METRIC_NAMESPACE = 'evo_flow_backfill_labels'.freeze
    IDENTIFY_PATH = '/events/identify'.freeze

    sidekiq_retries_exhausted do |job, ex|
      args = job['args'] || []
      account_id = args[0]
      safe_error = EvoFlow::PublishEventWorker.sanitize_error(ex)
      Rails.logger.error(
        "[EvoFlow][BackfillLabels] terminal failure account_id=#{account_id || 'ALL'} msg=#{safe_error}"
      )
      EvoFlow::BackfillFailureBroadcaster.new.broadcast_failed(
        account_id: account_id, error: safe_error
      )
    end

    def perform(account_id = nil, opts = {})
      @account_id = account_id
      return log_disabled unless EvoFlow.enabled?

      configure_run(opts)
      run_backfill
    rescue EvoFlow::InvalidEventName => e
      handle_invalid_event_name(e)
      raise
    end

    private

    def configure_run(opts)
      opts = (opts || {}).transform_keys(&:to_s)
      @dry_run = opts.fetch('dry_run', true)
      @label_id_by_name = Label.pluck(:title, :id).to_h
      @sample_logged = false
    end

    def run_backfill
      cursor = Redis::Alfred.get(cursor_key).presence
      find_each_opts = { batch_size: SCAN_BATCH_SIZE }
      find_each_opts[:start] = cursor if cursor

      processed = 0
      taggings_relation.find_each(**find_each_opts) do |tagging|
        payload = build_payload(tagging)
        if payload.nil?
          increment_metric(:skipped)
        else
          log_sample(payload)
          enqueue_or_log(payload)
          increment_metric(:processed)
          processed += 1
        end
        Redis::Alfred.set(cursor_key, tagging.id) unless @dry_run
      end

      log_summary(processed)
      Redis::Alfred.delete(cursor_key) unless @dry_run
    end

    def taggings_relation
      ActsAsTaggableOn::Tagging
        .joins(:tag)
        .where(taggable_type: 'Contact', context: 'labels')
        .order(:id)
    end

    # contact_id/tag.name are non-null DB columns (taggable_id, tags.name) —
    # the nil guard here only covers a tagging left dangling by a hard DELETE
    # that bypassed AR callbacks (migration, console, bulk SQL).
    def build_payload(tagging)
      return nil if tagging.taggable_id.nil? || tagging.tag&.name.blank?

      label_name = tagging.tag.name
      label_id = @label_id_by_name[label_name] || label_name
      occurred_at = tagging.created_at || Time.current
      message_id = EvoFlow::BackfillMapper.message_id_for(:contact_label, tagging.id)

      EvoFlow::PayloadBuilder.build_identify(
        event_name: 'contact.label.added',
        contact_id: tagging.taggable_id,
        traits: { labelName: label_name, labelId: label_id, source: 'backfill' },
        occurred_at: occurred_at,
        message_id: message_id
      )
    end

    def enqueue_or_log(payload)
      return if @dry_run

      # Sidekiq strict_args!(:raise) rejects symbol keys — round-trip through
      # JSON to normalise, same as ContactEventsListener#enqueue_identify.
      EvoFlow::PublishEventWorker.perform_async(IDENTIFY_PATH, JSON.parse(payload.to_json))
    end

    def cursor_key
      base = "backfill:cursor:labels:#{@account_id || 'ALL'}"
      @dry_run ? "dry_run:#{base}" : base
    end

    def increment_metric(name)
      key = "#{METRIC_NAMESPACE}:#{name}"
      key = "dry_run:#{key}" if @dry_run
      Redis::Alfred.incr(key)
    end

    def log_sample(payload)
      return if @sample_logged

      @sample_logged = true
      sanitized = EvoFlow::PublishEventWorker.sanitize_payload(payload.transform_keys(&:to_s))
      Rails.logger.info("[EvoFlow][BackfillLabels] sample_payload payload=#{sanitized.inspect}")
    end

    def log_summary(processed)
      prefix = @dry_run ? 'would_backfill' : 'backfilled'
      Rails.logger.info(
        "[EvoFlow][BackfillLabels] #{prefix} account=#{@account_id || 'ALL'} count=#{processed}"
      )
    end

    def log_disabled
      Rails.logger.warn(
        '[EvoFlow][BackfillLabels] skipped: EvoFlow integration is disabled ' \
        '(set EVO_FLOW_ENABLED=true or configure AUTH_APIKEY_INTEGRATION_LOCAL)'
      )
      nil
    end

    def handle_invalid_event_name(error)
      Rails.logger.error(
        "[EvoFlow][BackfillLabels] invalid_event_name account_id=#{@account_id || 'ALL'} msg=#{error.message}"
      )
      EvoFlow::BackfillFailureBroadcaster.new.broadcast_dropped(
        reason: :invalid_event_name, account_id: @account_id,
        source: 'contact_label', error_message: error.message
      )
    end
  end
end
