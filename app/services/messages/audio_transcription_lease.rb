# frozen_string_literal: true

# Coordinates the UI transcription job and the BotRuntime job so one attachment
# is sent to the provider at a time. The database compare-and-set is intentional:
# model-level validations cannot make this claim atomic across Sidekiq workers.
class Messages::AudioTranscriptionLease
  DURATION = 2.minutes

  def initialize(attachment)
    @attachment = attachment
  end

  def claim
    now = Time.current
    current_expiry = (@attachment.meta || {})['audio_transcription_processing_until']
    return :in_progress if active_expiry?(current_expiry, now)

    @expires_at = now + DURATION
    return :acquired if persist_claim(now)

    claim_conflict_status
  rescue ActiveRecord::StatementInvalid, ArgumentError, TypeError => e
    Rails.logger.warn "AudioTranscriptionService: Could not claim transcription lease: #{e.class}"
    :unavailable
  end

  def release
    return unless @claimed

    # rubocop:disable Rails/SkipsModelValidations -- atomic compare-and-set.
    Attachment.where(id: @attachment.id)
              .where("meta->>'audio_transcription_processing_until' = ?", @expires_at.iso8601)
              .update_all(["meta = meta - 'audio_transcription_processing_until', updated_at = ?", Time.current])
    # rubocop:enable Rails/SkipsModelValidations
    @claimed = false
  rescue StandardError => e
    Rails.logger.warn "AudioTranscriptionService: Could not release transcription lease: #{e.class}"
  end

  private

  def persist_claim(now)
    # rubocop:disable Rails/SkipsModelValidations -- atomic compare-and-set.
    @claimed = Attachment.where(id: @attachment.id)
                         .where(expired_or_missing_lease_condition, now)
                         .update_all(
                           [
                             claim_update,
                             { audio_transcription_processing_until: @expires_at.iso8601 }.to_json,
                             now
                           ]
                         ).positive?
    # rubocop:enable Rails/SkipsModelValidations
  end

  def claim_conflict_status
    current_meta = Attachment.where(id: @attachment.id).pick(:meta) || {}
    return :completed if current_meta['transcribed_text'].present?
    return :in_progress if active_expiry?(current_meta['audio_transcription_processing_until'], Time.current)

    :unavailable
  end

  def active_expiry?(value, now)
    value.present? && Time.zone.parse(value) > now
  rescue ArgumentError, TypeError
    false
  end

  def expired_or_missing_lease_condition
    <<~SQL.squish
      meta IS NULL OR meta->>'audio_transcription_processing_until' IS NULL OR
      (meta->>'audio_transcription_processing_until')::timestamptz <= ?
    SQL
  end

  def claim_update
    "meta = COALESCE(meta, '{}'::jsonb) || ?::jsonb, updated_at = ?"
  end
end
