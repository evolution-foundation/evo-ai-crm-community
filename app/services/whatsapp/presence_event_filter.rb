# frozen_string_literal: true

# Whatsapp::PresenceEventFilter
#
# Each WhatsApp provider names its presence states differently. This is the
# single place that decides which raw state values count as "the customer is
# actively typing/recording" (and should extend the AI's debounce timer) vs.
# everything else (available/unavailable/online/offline/paused), which is a
# no-op by explicit product decision — paused never triggers anything.
module Whatsapp::PresenceEventFilter
  TYPING_STATES = {
    evolution: %w[composing recording],
    evolution_go: %w[composing],
    waha: %w[typing recording]
  }.freeze

  module_function

  def typing?(provider, state)
    TYPING_STATES.fetch(provider, []).include?(state)
  end
end
