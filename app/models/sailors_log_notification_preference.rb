class SailorsLogNotificationPreference < ApplicationRecord
  before_validation :ensure_sailors_log_exists

  belongs_to :sailors_log,
             class_name: "SailorsLog",
             foreign_key: :slack_uid,
             primary_key: :slack_uid

  validates :slack_uid, uniqueness: {
    scope: :slack_channel_id,
    message: "already has a notification preference for this channel"
  }

  private

  def ensure_sailors_log_exists
    return if sailors_log.present?

    sailors_log = SailorsLog.find_or_create_by(slack_uid: slack_uid)
    self.sailors_log = sailors_log
    sailors_log.send(:initialize_projects_summary)
  end
end
