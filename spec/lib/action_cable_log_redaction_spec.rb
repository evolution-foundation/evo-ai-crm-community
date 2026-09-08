# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ActionCableLogRedaction do
  let(:jwt) { 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc-DEF_123' }

  describe '.redact' do
    it 'redacts the raw JSON identifier ActionCable logs on unsubscribe' do
      line = %(Unsubscribing from channel: {"channel":"RoomChannel","pubsub_token":"p1","user_id":"u1","access_token":"#{jwt}"})

      expect(described_class.redact(line)).to eq(
        %(Unsubscribing from channel: {"channel":"RoomChannel","pubsub_token":"[REDACTED]","user_id":"u1","access_token":"[REDACTED]"})
      )
    end

    it 'redacts the escaped JSON inside the inspected command hash' do
      identifier = %({\\"channel\\":\\"RoomChannel\\",\\"access_token\\":\\"#{jwt}\\"})
      line = %(Could not execute command from ({"command"=>"unsubscribe", "identifier"=>"#{identifier}"}) [RuntimeError - x])

      expect(described_class.redact(line)).not_to include(jwt)
      expect(described_class.redact(line)).to include('\\"access_token\\":\\"[REDACTED]\\"')
    end

    it 'redacts the doubly escaped identifier of a frame logged after the socket closed' do
      frame = %("{\\"command\\":\\"message\\",\\"identifier\\":\\"{\\\\\\"access_token\\\\\\":\\\\\\"#{jwt}\\\\\\"}\\"}")
      line = %(Ignoring message processed after the WebSocket was closed: #{frame})

      expect(described_class.redact(line)).not_to include(jwt)
      expect(described_class.redact(line)).to include('[REDACTED]')
    end

    it 'redacts a Ruby hash inspect' do
      expect(described_class.redact(%({"access_token"=>"#{jwt}", "user_id"=>"u1"}))).to eq(%({"access_token"=>"[REDACTED]", "user_id"=>"u1"}))
      expect(described_class.redact(%({"access_token" => "#{jwt}"}))).to eq(%({"access_token" => "[REDACTED]"}))
    end

    it 'redacts a query string form' do
      expect(described_class.redact("GET /cable?access_token=#{jwt}&x=1")).to eq('GET /cable?access_token=[REDACTED]&x=1')
    end

    it 'redacts the widget contact credential too' do
      expect(described_class.redact(%({"channel":"RoomChannel","pubsub_token":"ZvDAduw9"})))
        .to eq(%({"channel":"RoomChannel","pubsub_token":"[REDACTED]"}))
    end

    it 'leaves other fields and non-string messages untouched' do
      expect(described_class.redact(%({"channel":"RoomChannel","user_id":"u1"}))).to eq(%({"channel":"RoomChannel","user_id":"u1"}))
      expect(described_class.redact(nil)).to be_nil
      expect(described_class.redact(42)).to eq(42)
    end
  end

  describe ActionCableLogRedaction::Logger do
    let(:io) { StringIO.new }
    let(:base) { ActiveSupport::TaggedLogging.new(Logger.new(io)) }
    let(:logger) { described_class.new(base) }

    it 'redacts every severity, including the block form' do
      logger.info(%({"access_token":"#{jwt}"}))
      logger.error { %({"access_token":"#{jwt}"}) }
      logger.add(Logger::WARN, %(access_token=#{jwt}))

      expect(io.string).not_to include(jwt)
      expect(io.string.scan('[REDACTED]').size).to eq(3)
    end

    it 'redacts the progname Logger#add uses as the message when message is nil' do
      logger.add(Logger::INFO, nil, %({"access_token":"#{jwt}"}))

      expect(io.string).not_to include(jwt)
      expect(io.string).to include('[REDACTED]')
    end

    it 'keeps tagging working for the ActionCable TaggedLoggerProxy' do
      proxy = ActionCable::Connection::TaggedLoggerProxy.new(logger, tags: ['ws'])

      proxy.info(%(Unsubscribing from channel: {"access_token":"#{jwt}"}))

      expect(io.string).to include('[ws]')
      expect(io.string).not_to include(jwt)
    end
  end

  it 'is installed on the ActionCable server logger' do
    expect(ActionCable.server.config.logger).to be_a(ActionCableLogRedaction::Logger)
  end

  it 'does not wrap twice' do
    config = ActionCable.server.config
    described_class.install!(config)

    expect(config.logger.__getobj__).not_to be_a(ActionCableLogRedaction::Logger)
  end
end
