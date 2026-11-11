# frozen_string_literal: true

require 'rails_helper'

# Regression coverage for the lunch-break (second time slot) feature end-to-end
# through the actual path the frontend uses: Inbox#update_working_hours (called
# from InboxesController#update_inbox_working_hours with a `working_hours` array
# param), not the separate/lesser-used WorkingHoursController#update.
RSpec.describe OutOfOffisable do
  let(:channel) { Channel::Api.create! }
  let(:inbox) { Inbox.create!(name: 'API Inbox', channel: channel, timezone: 'UTC') }

  describe '#update_working_hours and #weekly_schedule' do
    it 'persists and echoes back the second time slot for a given day' do
      inbox.update_working_hours([
                                    {
                                      'day_of_week' => 1,
                                      'closed_all_day' => false,
                                      'open_all_day' => false,
                                      'open_hour' => 9,
                                      'open_minutes' => 0,
                                      'close_hour' => 12,
                                      'close_minutes' => 0,
                                      'open_hour_2' => 13,
                                      'open_minutes_2' => 0,
                                      'close_hour_2' => 18,
                                      'close_minutes_2' => 0
                                    }
                                  ])

      monday = inbox.weekly_schedule.find { |d| d['day_of_week'] == 1 }

      expect(monday['open_hour_2']).to eq(13)
      expect(monday['close_hour_2']).to eq(18)
    end

    it 'clears a previously-set second slot when updated without one' do
      inbox.update_working_hours([
                                    {
                                      'day_of_week' => 1,
                                      'closed_all_day' => false,
                                      'open_all_day' => false,
                                      'open_hour' => 9,
                                      'open_minutes' => 0,
                                      'close_hour' => 12,
                                      'close_minutes' => 0,
                                      'open_hour_2' => 13,
                                      'open_minutes_2' => 0,
                                      'close_hour_2' => 18,
                                      'close_minutes_2' => 0
                                    }
                                  ])

      inbox.update_working_hours([
                                    {
                                      'day_of_week' => 1,
                                      'closed_all_day' => false,
                                      'open_all_day' => false,
                                      'open_hour' => 9,
                                      'open_minutes' => 0,
                                      'close_hour' => 17,
                                      'close_minutes' => 0,
                                      'open_hour_2' => nil,
                                      'open_minutes_2' => nil,
                                      'close_hour_2' => nil,
                                      'close_minutes_2' => nil
                                    }
                                  ])

      monday = inbox.weekly_schedule.find { |d| d['day_of_week'] == 1 }

      expect(monday['open_hour_2']).to be_nil
      expect(monday['close_hour']).to eq(17)
    end
  end
end
