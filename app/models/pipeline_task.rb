# == Schema Information
#
# Table name: pipeline_tasks
#
#  id               :uuid             not null, primary key
#  completed_at     :datetime
#  depth            :integer          default(0), not null
#  description      :text
#  due_date         :datetime
#  metadata         :jsonb
#  position         :integer          default(0), not null
#  priority         :integer          default("low"), not null
#  status           :integer          default("pending"), not null
#  task_type        :integer          default("call"), not null
#  title            :string(255)      not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  assigned_to_id   :uuid
#  created_by_id    :uuid             not null
#  parent_task_id   :uuid
#  pipeline_item_id :uuid             not null
#
# Indexes
#
#  index_pipeline_tasks_on_assigned_to_id_and_status_and_due_date  (assigned_to_id,status,due_date)
#  index_pipeline_tasks_on_created_by_id                           (created_by_id)
#  index_pipeline_tasks_on_due_date                                (due_date)
#  index_pipeline_tasks_on_parent_task_id                          (parent_task_id)
#  index_pipeline_tasks_on_parent_task_id_and_position             (parent_task_id,position)
#  index_pipeline_tasks_on_pending_status_and_due_date             (status,due_date) WHERE (status = 0)
#  index_pipeline_tasks_on_pipeline_item_id                        (pipeline_item_id)
#  index_pipeline_tasks_on_pipeline_item_id_and_parent_task_id     (pipeline_item_id,parent_task_id)
#  index_pipeline_tasks_on_pipeline_item_id_and_status             (pipeline_item_id,status)
#
# Foreign Keys
#
#  fk_rails_...  (parent_task_id => pipeline_tasks.id)
#  fk_rails_...  (pipeline_item_id => pipeline_items.id)
#

class PipelineTask < ApplicationRecord
  include Events::Types
  include Wisper::Publisher

  # Associations
  belongs_to :pipeline_item
  belongs_to :created_by, class_name: 'User'
  belongs_to :assigned_to, class_name: 'User', optional: true

  # Hierarchy associations
  belongs_to :parent_task, class_name: 'PipelineTask', optional: true
  has_many :subtasks, class_name: 'PipelineTask', foreign_key: 'parent_task_id', dependent: :destroy

  has_one :pipeline, through: :pipeline_item
  has_one :conversation, through: :pipeline_item
  has_one :contact, through: :pipeline_item

  # Enums
  enum task_type: {
    call: 0,
    email: 1,
    meeting: 2,
    follow_up: 3,
    note: 4,
    other: 5
  }, _prefix: true

  enum status: {
    pending: 0,
    completed: 1,
    cancelled: 2,
    overdue: 3
  }, _prefix: true

  enum priority: {
    low: 0,
    medium: 1,
    high: 2,
    urgent: 3
  }, _prefix: true

  # Validations
  validates :title, presence: true, length: { maximum: 255 }
  validates :task_type, presence: true
  validates :status, presence: true
  validates :priority, presence: true

  validate :due_date_cannot_exceed_parent, if: :parent_task_id?
  validate :parent_task_belongs_to_same_pipeline_item
  validate :prevent_circular_hierarchy
  validate :max_hierarchy_depth

  # Scopes
  scope :pending, -> { where(status: :pending) }
  scope :completed, -> { where(status: :completed) }
  scope :cancelled, -> { where(status: :cancelled) }
  scope :overdue, -> { where(status: :overdue) }

  scope :due_today, -> { where('DATE(due_date) = ?', Date.current) }
  scope :due_this_week, -> { where(due_date: Date.current.all_week) }
  scope :due_soon, -> { where('due_date <= ? AND due_date > ?', 1.hour.from_now, Time.current) }
  scope :past_due, -> { pending.where('due_date < ?', Time.current) }

  scope :assigned_to_user, ->(user) { where(assigned_to_id: user.id) }
  scope :created_by_user, ->(user) { where(created_by_id: user.id) }

  scope :with_due_date, -> { where.not(due_date: nil) }
  scope :ordered_by_due_date, -> { order(due_date: :asc) }
  scope :ordered_by_priority, -> { order(priority: :desc, due_date: :asc) }

  # Hierarchy scopes
  scope :root_tasks, -> { where(parent_task_id: nil) }
  scope :subtasks_of, ->(task_id) { where(parent_task_id: task_id) }
  scope :by_position, -> { order(:position) }

  # Callbacks
  before_validation :set_depth, if: :parent_task_id_changed?
  before_update :prevent_update_if_completed, unless: :status_changed?
  before_create :set_default_position
  after_destroy :reorder_siblings
  
  after_create :publish_task_created_event
  after_update :publish_task_updated_event, if: :saved_change_to_status?
  after_update :set_completed_at, if: :saved_change_to_status?

  MAX_DEPTH = 2 # 0 = root, 1 = subtask level 1, 2 = subtask level 2 (max 3 levels total)

  # Instance Methods
  def overdue?
    due_date.present? && due_date < Time.current && status_pending?
  end

  def due_soon?
    due_date.present? && due_date <= 1.hour.from_now && due_date > Time.current && status_pending?
  end

  def completed?
    completed_at.present? && status_completed?
  end

  def mark_as_completed(user = nil)
    transaction do
      update!(
        status: :completed,
        completed_at: Time.current,
        metadata: metadata.merge(completed_by_id: user&.id)
      )
      
      # Complete ALL descendants recursively (all levels below)
      complete_all_descendants(user)
    end
    
    true
  rescue StandardError => e
    Rails.logger.error("Error completing task #{id}: #{e.message}")
    errors.add(:base, e.message)
    false
  end

  def mark_as_cancelled(user = nil)
    update(
      status: :cancelled,
      metadata: metadata.merge(cancelled_by_id: user&.id)
    )
  end

  def mark_as_overdue
    return unless overdue? && !status_overdue?

    update!(status: :overdue)
  end

  def reopen
    return false unless status_completed? || status_cancelled?

    transaction do
      update!(
        status: :pending,
        completed_at: nil
      )
      
      # Reopen ALL descendants recursively (all levels below)
      reopen_all_descendants
    end
    
    true
  rescue StandardError => e
    Rails.logger.error("Error reopening task #{id}: #{e.message}")
    errors.add(:base, e.message)
    false
  end

  def assigned?
    assigned_to_id.present?
  end

  def days_until_due
    return nil if due_date.blank?

    ((due_date.to_date - Date.current).to_i)
  end

  def hours_until_due
    return nil if due_date.blank?

    ((due_date - Time.current) / 1.hour).round(1)
  end

  # Hierarchy methods
  def root_task?
    parent_task_id.nil?
  end

  def has_subtasks?
    subtasks.exists?
  end

  def subtask_count
    subtasks.count
  end

  def ancestors
    path = []
    current = self
    while current.parent_task.present?
      current = current.parent_task
      path << current
    end
    path
  end

  def descendants
    subtasks.flat_map { |st| [st] + st.descendants }
  end

  def siblings
    return PipelineTask.none if parent_task_id.nil?
    
    PipelineTask.where(parent_task_id: parent_task_id)
                .where.not(id: id)
                .order(:position)
  end

  def move_to_position(new_position)
    transaction do
      old_position = position
      
      if new_position > old_position
        siblings.where('position > ? AND position <= ?', old_position, new_position)
                .update_all('position = position - 1')
      else
        siblings.where('position >= ? AND position < ?', new_position, old_position)
                .update_all('position = position + 1')
      end
      
      update!(position: new_position)
    end
  end

  def move_to_parent(new_parent_id, new_position = nil)
    if status_completed?
      errors.add(:base, 'Cannot move completed tasks')
      return false
    end
    
    transaction do
      reorder_siblings if persisted?
      
      # Explicitly set parent_task_id (including nil for root promotion)
      self.parent_task_id = new_parent_id.presence
      set_depth
      
      if new_position
        self.position = new_position
      else
        max_position = PipelineTask.where(parent_task_id: new_parent_id)
                                   .maximum(:position) || -1
        self.position = max_position + 1
      end
      
      save!
      update_descendants_depth
    end
  end

  def complete_with_subtasks
    transaction do
      mark_as_completed
      subtasks.each(&:complete_with_subtasks)
    end
  end

  def completion_percentage
    return 100 if status_completed?
    return 0 unless has_subtasks?
    
    total = subtasks.count
    completed = subtasks.select(&:status_completed?).count
    (completed.to_f / total * 100).round
  end

  private

  def prevent_update_if_completed
    if status_was == 1 # completed status
      errors.add(:base, 'Cannot update completed tasks')
      throw(:abort)
    end
  end

  def due_date_cannot_exceed_parent
    return unless due_date.present? && parent_task.present? && parent_task.due_date.present?

    if due_date > parent_task.due_date
      errors.add(:due_date, 'cannot be later than parent task due date')
    end
  end

  def parent_task_belongs_to_same_pipeline_item
    return unless parent_task.present?
    return if parent_task.pipeline_item_id == pipeline_item_id
    
    errors.add(:parent_task, 'must belong to the same pipeline item')
  end

  def prevent_circular_hierarchy
    return unless parent_task.present?
    
    if id == parent_task_id
      errors.add(:parent_task, 'cannot be the same as the task')
      return
    end
    
    current = parent_task
    while current.present?
      if current.id == id
        errors.add(:parent_task, 'would create a circular reference')
        return
      end
      current = current.parent_task
    end
  end

  def max_hierarchy_depth
    return unless parent_task.present?
    
    if depth > MAX_DEPTH
      errors.add(:parent_task, "maximum depth of #{MAX_DEPTH + 1} levels exceeded")
    end
  end

  def set_depth
    self.depth = parent_task.present? ? parent_task.depth + 1 : 0
  end

  def set_default_position
    return if position.present? && position > 0
    
    max_position = PipelineTask.where(parent_task_id: parent_task_id)
                               .where.not(id: id)
                               .maximum(:position) || -1
    self.position = max_position + 1
  end

  def reorder_siblings
    return unless parent_task_id_was.present?
    
    PipelineTask.where(parent_task_id: parent_task_id_was)
                .where('position > ?', position_was || position)
                .update_all('position = position - 1')
  end

  def update_descendants_depth
    descendants.each do |descendant|
      new_depth = depth + (descendant.depth - depth)
      descendant.update_column(:depth, new_depth) if descendant.depth != new_depth
    end
  end

  def set_completed_at
    if status_completed? && completed_at.nil?
      # rubocop:disable Rails/SkipsModelValidations
      update_column(:completed_at, Time.current)
      # rubocop:enable Rails/SkipsModelValidations
    elsif !status_completed?
      # rubocop:disable Rails/SkipsModelValidations
      update_column(:completed_at, nil)
      # rubocop:enable Rails/SkipsModelValidations
    end
  end

  def complete_all_descendants(user)
    # Get all descendants at once (more efficient than recursive calls)
    all_descendants = descendants
    all_descendants.each do |descendant|
      next if descendant.status_completed?
      
      descendant.update!(
        status: :completed,
        completed_at: Time.current,
        metadata: descendant.metadata.merge(completed_by_id: user&.id)
      )
    end
  end

  def reopen_all_descendants
    # Get all descendants at once
    all_descendants = descendants
    all_descendants.each do |descendant|
      next if descendant.status_pending?
      
      descendant.update!(
        status: :pending,
        completed_at: nil
      )
    end
  end

  def publish_task_created_event
    publish_event('pipeline_task.created', Time.zone.now, task: self)
  end

  def publish_task_updated_event
    event_name = case status
                 when 'completed'
                   'pipeline_task.completed'
                 when 'cancelled'
                   'pipeline_task.cancelled'
                 when 'overdue'
                   'pipeline_task.overdue'
                 else
                   'pipeline_task.updated'
                 end

    publish_event(event_name, Time.zone.now, task: self)
  end

  def publish_event(event_name, timestamp, data)
    Rails.configuration.dispatcher.dispatch(event_name, timestamp, **data)
  end
end
