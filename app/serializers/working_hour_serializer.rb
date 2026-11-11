# frozen_string_literal: true

module WorkingHourSerializer
  extend self

  def serialize(working_hour, **options)
    return nil unless working_hour

    {
      id: working_hour.id,
      inbox_id: working_hour.inbox_id,
      day_of_week: working_hour.day_of_week,
      open_hour: working_hour.open_hour,
      open_minutes: working_hour.open_minutes,
      close_hour: working_hour.close_hour,
      close_minutes: working_hour.close_minutes,
      open_hour_2: working_hour.open_hour_2,
      open_minutes_2: working_hour.open_minutes_2,
      close_hour_2: working_hour.close_hour_2,
      close_minutes_2: working_hour.close_minutes_2,
      closed_all_day: working_hour.closed_all_day,
      open_all_day: working_hour.open_all_day,
      created_at: working_hour.created_at&.iso8601,
      updated_at: working_hour.updated_at&.iso8601
    }
  end

  def serialize_collection(working_hours, **options)
    return [] unless working_hours

    working_hours.map { |wh| serialize(wh, **options) }
  end
end
