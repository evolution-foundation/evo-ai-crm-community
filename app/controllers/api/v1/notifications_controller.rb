class Api::V1::NotificationsController < Api::V1::BaseController

  RESULTS_PER_PAGE = 15
  include DateRangeHelper

  before_action :fetch_notification, only: [:update, :destroy, :snooze, :unread]
  before_action :set_primary_actor, only: [:read_all]
  before_action :set_current_page, only: [:index]

  def index
    @notifications = notification_finder.notifications
    @unread_count = notification_finder.unread_count
    @count = notification_finder.count
    
    apply_pagination
    
    paginated_response(
      data: NotificationSerializer.serialize_collection(@notifications, include_actors: true),
      collection: @notifications,
      meta: {
        unread_count: @unread_count,
        count: @count
      }
    )
  end

  def read_all
    # rubocop:disable Rails/SkipsModelValidations
    if @primary_actor
      current_user.notifications.where(primary_actor: @primary_actor, read_at: nil)
                  .update_all(read_at: DateTime.now.utc)
    else
      current_user.notifications.where(read_at: nil).update_all(read_at: DateTime.now.utc)
    end
    # rubocop:enable Rails/SkipsModelValidations
    
    success_response(
      data: {},
      message: 'All notifications marked as read'
    )
  end

  def update
    @notification.update!(read_at: DateTime.now.utc)
    
    success_response(
      data: NotificationSerializer.serialize(@notification, include_actors: true),
      message: 'Notification marked as read'
    )
  end

  def unread
    @notification.update!(read_at: nil)
    
    success_response(
      data: NotificationSerializer.serialize(@notification, include_actors: true),
      message: 'Notification marked as unread'
    )
  end

  def destroy
    @notification.destroy
    
    success_response(
      data: { id: @notification.id },
      message: 'Notification deleted successfully'
    )
  end

  def destroy_all
    if params[:type] == 'read'
      ::Notification::DeleteNotificationJob.perform_later(Current.user, type: :read)
    else
      ::Notification::DeleteNotificationJob.perform_later(Current.user, type: :all)
    end
    
    success_response(
      data: {},
      message: 'Notifications deletion scheduled'
    )
  end

  def unread_count
    @unread_count = notification_finder.unread_count
    
    success_response(
      data: { unread_count: @unread_count },
      message: 'Unread count retrieved successfully'
    )
  end

  def snooze
    updated_meta = (@notification.meta || {}).merge('last_snoozed_at' => nil)
    @notification.update!(snoozed_until: parse_date_time(params[:snoozed_until].to_s), meta: updated_meta) if params[:snoozed_until]
    
    success_response(
      data: NotificationSerializer.serialize(@notification, include_actors: true),
      message: 'Notification snoozed successfully'
    )
  end

  private

  def set_primary_actor
    return unless params[:primary_actor_type]
    return unless Notification::PRIMARY_ACTORS.include?(params[:primary_actor_type])

    @primary_actor = params[:primary_actor_type].safe_constantize.find_by(id: params[:primary_actor_id])
  end

  def fetch_notification
    @notification = current_user.notifications.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      code: ApiErrorCodes::NOTIFICATION_NOT_FOUND,
      message: "Notification with id #{params[:id]} not found",
      status: :not_found
    )
  end

  def set_current_page
    @current_page = params[:page] || 1
  end

  def notification_finder
    @notification_finder ||= NotificationFinder.new(Current.user, nil, params)
  end
end
