# frozen_string_literal: true

module BotRuntime
  class CircuitBreaker
    STATES = %i[closed open half_open].freeze

    attr_reader :state, :failure_count

    def initialize(max_failures: 5, reset_timeout: 30)
      @max_failures = max_failures
      @reset_timeout = reset_timeout
      @failure_count = 0
      @state = :closed
      @last_failure_time = nil
      @mutex = Mutex.new
    end

    def call(&block)
      @mutex.synchronize do
        case @state
        when :open
          if Time.current - @last_failure_time >= @reset_timeout
            @state = :half_open
          else
            raise CircuitOpenError, 'Circuit breaker is open'
          end
        end
      end

      result = yield

      @mutex.synchronize do
        reset!
      end

      result
    rescue CircuitOpenError
      raise
    rescue StandardError => e
      @mutex.synchronize do
        record_failure!
      end
      raise e
    end

    private

    def record_failure!
      @failure_count += 1
      @last_failure_time = Time.current

      if @failure_count >= @max_failures
        @state = :open
        Rails.logger.warn "[BotRuntime::CircuitBreaker] Circuit opened after #{@failure_count} failures"
      end
    end

    def reset!
      @failure_count = 0
      @state = :closed
    end

    class CircuitOpenError < StandardError; end
  end
end
