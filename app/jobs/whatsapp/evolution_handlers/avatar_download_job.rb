# frozen_string_literal: true

# Wraps Avatar::AvatarFromUrlJob so the enqueue debounce lock (see
# Whatsapp::EvolutionHandlers::AvatarEnqueueGuard) always releases once the
# download attempt is over — success, silent failure (blocked SSRF, 404,
# transient network error swallowed inside AvatarFromUrlJob), or an unexpected
# raise. Without this, a URL that resolved but failed to download left the
# contact locked out of a retry for the full one-hour TTL (Sourcery finding,
# PR #373). Avatar::AvatarFromUrlJob itself stays generic — every other caller
# (AgentBot, Twitter, Telegram, etc.) doesn't use this lock at all.
class Whatsapp::EvolutionHandlers::AvatarDownloadJob < ApplicationJob
  queue_as :low

  def perform(contact, avatar_url)
    Avatar::AvatarFromUrlJob.new.perform(contact, avatar_url)
  ensure
    Whatsapp::EvolutionHandlers::AvatarEnqueueGuard.release_avatar_enqueue_lock(contact.id)
  end
end
