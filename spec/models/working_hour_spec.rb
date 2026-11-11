# frozen_string_literal: true

require 'rails_helper'

RSpec.describe WorkingHour do
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: channel, timezone: 'UTC') }
  let(:monday) { inbox.working_hours.find_by(day_of_week: 1) }

  describe 'second time slot (lunch break) validations' do
    it 'is valid without a second slot' do
      monday.assign_attributes(open_hour: 9, open_minutes: 0, close_hour: 17, close_minutes: 0)
      expect(monday).to be_valid
    end

    it 'is valid with a complete second slot after the first' do
      monday.assign_attributes(
        open_hour: 9, open_minutes: 0, close_hour: 12, close_minutes: 0,
        open_hour_2: 13, open_minutes_2: 0, close_hour_2: 18, close_minutes_2: 0
      )
      expect(monday).to be_valid
    end

    it 'rejects a partially filled second slot' do
      monday.assign_attributes(
        open_hour: 9, open_minutes: 0, close_hour: 17, close_minutes: 0,
        open_hour_2: 13
      )
      expect(monday).not_to be_valid
      expect(monday.errors[:base]).to be_present
    end

    it 'rejects a second slot that closes before it opens' do
      monday.assign_attributes(
        open_hour: 9, open_minutes: 0, close_hour: 12, close_minutes: 0,
        open_hour_2: 14, open_minutes_2: 0, close_hour_2: 13, close_minutes_2: 0
      )
      expect(monday).not_to be_valid
      expect(monday.errors[:close_hour_2]).to be_present
    end

    it 'rejects a second slot that starts before the first slot ends' do
      monday.assign_attributes(
        open_hour: 9, open_minutes: 0, close_hour: 12, close_minutes: 0,
        open_hour_2: 11, open_minutes_2: 0, close_hour_2: 18, close_minutes_2: 0
      )
      expect(monday).not_to be_valid
      expect(monday.errors[:open_hour_2]).to be_present
    end

    it 'clears the second slot when open_all_day is set (24h has no break)' do
      monday.assign_attributes(
        open_hour: 9, open_minutes: 0, close_hour: 12, close_minutes: 0,
        open_hour_2: 13, open_minutes_2: 0, close_hour_2: 18, close_minutes_2: 0,
        open_all_day: true
      )
      monday.valid?

      expect(monday.open_hour_2).to be_nil
      expect(monday.close_hour_2).to be_nil
    end
  end

  describe '#open_at?' do
    before do
      monday.update!(
        open_hour: 9, open_minutes: 0, close_hour: 12, close_minutes: 0,
        open_hour_2: 13, open_minutes_2: 0, close_hour_2: 18, close_minutes_2: 0
      )
    end

    it 'is open during the morning window' do
      expect(monday.open_at?(Time.zone.now.change(hour: 10, min: 0))).to be(true)
    end

    it 'is closed during the lunch break gap' do
      expect(monday.open_at?(Time.zone.now.change(hour: 12, min: 30))).to be(false)
    end

    it 'is open during the afternoon window' do
      expect(monday.open_at?(Time.zone.now.change(hour: 15, min: 0))).to be(true)
    end

    it 'is closed outside both windows' do
      expect(monday.open_at?(Time.zone.now.change(hour: 20, min: 0))).to be(false)
    end
  end
end
