class User < ApplicationRecord
  has_paper_trail
  encrypts :slack_access_token

  validates :email, presence: true, uniqueness: true
  validates :slack_uid, presence: true, uniqueness: true
  validates :username, presence: true

  has_many :heartbeats,
    foreign_key: :user_id,
    primary_key: :slack_uid,
    class_name: "Heartbeat"

  has_many :project_labels,
    foreign_key: :user_id,
    primary_key: :slack_uid,
    class_name: "ProjectLabel"

  def admin?
    is_admin
  end

  def make_admin!
    update!(is_admin: true)
  end

  def remove_admin!
    update!(is_admin: false)
  end

  def update_slack_status
    return unless uses_slack_status?

    # check if the user already has a custom status set– if it doesn't look like
    # our format, don't clobber it

    current_status_response = HTTP.auth("Bearer #{slack_access_token}")
      .get("https://slack.com/api/users.profile.get")

    current_status = JSON.parse(current_status_response.body.to_s)

    custom_status_regex = /spent on \w+ today$/
    status_present = current_status.dig("profile", "status_text").present?
    status_custom = !current_status.dig("profile", "status_text").match?(custom_status_regex)

    return if status_present && status_custom

    current_project = heartbeats.order(time: :desc).first&.project
    current_project_heartbeats = heartbeats.today.where(project: current_project)
    current_project_duration = Heartbeat.duration_seconds(current_project_heartbeats)
    current_project_duration_formatted = Heartbeat.duration_simple(current_project_heartbeats)

    # for 0 duration, don't set a status
    return if current_project_duration.zero?

    status_emoji =
      case current_project_duration
      when 0...30.minutes
        %w[thinking cat-on-the-laptop loading-tumbleweed rac-yap]
      when 30.minutes...1.hour
        %w[working-parrot meow_code]
      when 1.hour...2.hours
        %w[working-parrot meow-code]
      when 2.hours...3.hours
        %w[working-parrot cat-typing bangbang]
      when 3.hours...5.hours
        %w[cat-typing meow-code laptop-fire bangbang]
      when 5.hours...8.hours
        %w[cat-typing laptop-fire hole-mantelpiece_clock keyboard-fire bangbang bangbang]
      when 8.hours...15.hours
        %w[laptop-fire bangbang bangbang rac_freaking rac_freakinghole-mantelpiece_clock]
      when 15.hours...20.hours
        %w[bangbang bangbang rac_freaking hole-mantelpiece_clock]
      else
        %w[areyousure time-to-stop]
      end.sample

    status_emoji = ":#{status_emoji}:"
    status_text = "#{current_project_duration_formatted} spent on #{current_project} today"

    # Update the user's status
    HTTP.auth("Bearer #{slack_access_token}")
      .post("https://slack.com/api/users.profile.set", form: {
        profile: {
          status_text:,
          status_emoji:,
          status_expiration: Date.today.to_time.to_i + (1.hour.to_i * 1000)
        }
      })
  end

  def self.authorize_url(redirect_uri)
    params = {
      client_id: ENV["SLACK_CLIENT_ID"],
      redirect_uri: redirect_uri,
      state: SecureRandom.hex(24),
      user_scope: "users.profile:read,users.profile:write,users:read,users:read.email"
    }

    URI.parse("https://slack.com/oauth/v2/authorize?#{params.to_query}")
  end

  def self.from_slack_token(code, redirect_uri)
    # Exchange code for token
    response = HTTP.post("https://slack.com/api/oauth.v2.access", form: {
      client_id: ENV["SLACK_CLIENT_ID"],
      client_secret: ENV["SLACK_CLIENT_SECRET"],
      code: code,
      redirect_uri: redirect_uri
    })

    data = JSON.parse(response.body.to_s)

    return nil unless data["ok"]

    # Get user info
    user_response = HTTP.auth("Bearer #{data['authed_user']['access_token']}")
      .get("https://slack.com/api/users.info?user=#{data['authed_user']['id']}")

    user_data = JSON.parse(user_response.body.to_s)

    return nil unless user_data["ok"]

    user = find_or_initialize_by(slack_uid: data.dig("authed_user", "id"))
    user.email = user_data.dig("user", "profile", "email")
    user.username = user_data.dig("user", "name")
    user.avatar_url = user_data.dig("user", "profile", "image_192") || user_data.dig("user", "profile", "image_72")
    # Store the OAuth data
    user.slack_access_token = data["authed_user"]["access_token"]
    user.slack_scopes = data["authed_user"]["scope"]&.split(/,\s*/)
    user.save!
    user
  rescue => e
    Rails.logger.error "Error creating user from Slack data: #{e.message}"
    nil
  end

  def project_names
    heartbeats.select(:project).distinct.pluck(:project)
  end

  def active_project
    heartbeats.order(time: :desc).first&.project
  end

  def active_project_duration
    return nil unless active_project

    heartbeats.where(project: active_project).duration_seconds
  end
end
