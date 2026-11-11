# == Schema Information
#
# Table name: working_hours
#
#  id              :uuid             not null, primary key
#  close_hour      :integer
#  close_hour_2    :integer
#  close_minutes   :integer
#  close_minutes_2 :integer
#  closed_all_day  :boolean          default(FALSE)
#  day_of_week     :integer          not null
#  open_all_day    :boolean          default(FALSE)
#  open_hour       :integer
#  open_hour_2     :integer
#  open_minutes    :integer
#  open_minutes_2  :integer
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  inbox_id        :uuid
#
# Indexes
#
#  index_working_hours_on_inbox_id  (inbox_id)
#
class WorkingHour < ApplicationRecord
  belongs_to :inbox

  before_validation :ensure_open_all_day_hours

  validates :open_hour,     presence: true, unless: :closed_all_day?
  validates :open_minutes,  presence: true, unless: :closed_all_day?
  validates :close_hour,    presence: true, unless: :closed_all_day?
  validates :close_minutes, presence: true, unless: :closed_all_day?

  validates :open_hour,     inclusion: 0..23, unless: :closed_all_day?
  validates :close_hour,    inclusion: 0..23, unless: :closed_all_day?
  validates :open_minutes,  inclusion: 0..59, unless: :closed_all_day?
  validates :close_minutes, inclusion: 0..59, unless: :closed_all_day?

  validates :open_hour_2,     inclusion: 0..23, allow_nil: true
  validates :close_hour_2,    inclusion: 0..23, allow_nil: true
  validates :open_minutes_2,  inclusion: 0..59, allow_nil: true
  validates :close_minutes_2, inclusion: 0..59, allow_nil: true

  validate :close_after_open, unless: :closed_all_day?
  validate :open_all_day_and_closed_all_day
  validate :second_slot_fully_present_or_absent, unless: :closed_all_day?
  validate :close_after_open_second_slot, if: :second_slot_present?
  validate :second_slot_after_first_slot, if: :second_slot_present?

  def self.today
    # While getting the day of the week, consider the timezone as well. `first` would
    # return the first working hour from the list of working hours available per week.
    inbox = first.inbox
    find_by(day_of_week: Time.zone.now.in_time_zone(inbox.timezone).to_date.wday)
  end

  # A lunch break is represented as an optional second (open_2, close_2) window on the
  # same day: e.g. 09:00-12:00 (morning) + 13:00-18:00 (afternoon), with the gap between
  # close and open_2 being the break. open_at? is true if `time` falls in EITHER window.
  def open_at?(time)
    return false if closed_all_day?

    within_window?(time, open_hour, open_minutes, close_hour, close_minutes) ||
      (second_slot_present? && within_window?(time, open_hour_2, open_minutes_2, close_hour_2, close_minutes_2))
  end

  def open_now?
    inbox_time = Time.zone.now.in_time_zone(inbox.timezone)
    open_at?(inbox_time)
  end

  def closed_now?
    !open_now?
  end

  private

  def within_window?(time, open_h, open_m, close_h, close_m)
    open_time = Time.zone.now.in_time_zone(inbox.timezone).change({ hour: open_h, min: open_m })
    close_time = Time.zone.now.in_time_zone(inbox.timezone).change({ hour: close_h, min: close_m })

    time.between?(open_time, close_time)
  end

  def close_after_open
    return unless open_hour.hours + open_minutes.minutes >= close_hour.hours + close_minutes.minutes

    errors.add(:close_hour, 'Closing time cannot be before opening time')
  end

  def ensure_open_all_day_hours
    return unless open_all_day?

    self.open_hour = 0
    self.open_minutes = 0
    self.close_hour = 23
    self.close_minutes = 59
    self.open_hour_2 = nil
    self.open_minutes_2 = nil
    self.close_hour_2 = nil
    self.close_minutes_2 = nil
  end

  def open_all_day_and_closed_all_day
    return unless open_all_day? && closed_all_day?

    errors.add(:base, 'open_all_day and closed_all_day cannot be true at the same time')
  end

  def second_slot_present?
    [open_hour_2, open_minutes_2, close_hour_2, close_minutes_2].any?(&:present?)
  end

  def second_slot_fully_present_or_absent
    fields = [open_hour_2, open_minutes_2, close_hour_2, close_minutes_2]
    return if fields.all?(&:nil?) || fields.all?(&:present?)

    errors.add(:base, 'Second time slot must have all fields set or none (open_hour_2/open_minutes_2/close_hour_2/close_minutes_2)')
  end

  def close_after_open_second_slot
    return unless open_hour_2 && open_minutes_2 && close_hour_2 && close_minutes_2
    return unless open_hour_2.hours + open_minutes_2.minutes >= close_hour_2.hours + close_minutes_2.minutes

    errors.add(:close_hour_2, 'Second slot closing time cannot be before its opening time')
  end

  def second_slot_after_first_slot
    return unless open_hour && open_minutes && open_hour_2 && open_minutes_2
    return unless open_hour_2.hours + open_minutes_2.minutes <= close_hour.hours + close_minutes.minutes

    errors.add(:open_hour_2, 'Second time slot must start after the first slot ends')
  end
end
