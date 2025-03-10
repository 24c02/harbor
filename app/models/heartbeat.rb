class Heartbeat < WakatimeRecord
  TIMEOUT_DURATION = 2.minutes

  def self.cached_recent_count
    Rails.cache.fetch("heartbeats_recent_count", expires_in: 5.minutes) do
      recent.size
    end
  end

  scope :recent, -> { where("time > ?", 24.hours.ago) }
  scope :today, -> { where("DATE(time) = ?", Date.current) }

  # This is a hack to avoid using the default Rails inheritance column– Rails is confused by the field `type` in the db
  self.inheritance_column = nil
  # Prevent collision with Ruby's hash method
  self.ignored_columns += [ "hash" ]

  def self.duration_seconds(scope = all)
    if scope.group_values.any?
      group_column = scope.group_values.first

      # Don't quote if it's a SQL function (contains parentheses)
      group_expr = group_column.to_s.include?("(") ? group_column : connection.quote_column_name(group_column)

      capped_diffs = scope
        .select("#{group_expr} as grouped_time, CASE
          WHEN LAG(time) OVER (PARTITION BY #{group_expr} ORDER BY time) IS NULL THEN 0
          ELSE LEAST(EXTRACT(EPOCH FROM (time - LAG(time) OVER (PARTITION BY #{group_expr} ORDER BY time))), #{TIMEOUT_DURATION.to_i})
        END as diff")
        .where.not(time: nil)
        .order(time: :asc)
        .unscope(:group)

      connection.select_all(
        "SELECT grouped_time, COALESCE(SUM(diff), 0)::integer as duration
         FROM (#{capped_diffs.to_sql}) AS diffs
         GROUP BY grouped_time"
      ).each_with_object({}) do |row, hash|
        hash[row["grouped_time"]] = row["duration"].to_i
      end
    else
      # when not grouped, return a single value
      capped_diffs = scope
        .select("CASE
          WHEN LAG(time) OVER (ORDER BY time) IS NULL THEN 0
          ELSE LEAST(EXTRACT(EPOCH FROM (time - LAG(time) OVER (ORDER BY time))), #{TIMEOUT_DURATION.to_i})
        END as diff")
        .where.not(time: nil)
        .order(time: :asc)

      connection.select_value("SELECT COALESCE(SUM(diff), 0)::integer FROM (#{capped_diffs.to_sql}) AS diffs").to_i
    end
  end

  def self.duration_formatted(scope = all)
    seconds = duration_seconds(scope)
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60
    remaining_seconds = seconds % 60

    format("%02d:%02d:%02d", hours, minutes, remaining_seconds)
  end

  def self.duration_simple(scope = all)
    # 3 hours 10 min => "3 hrs"
    # 1 hour 10 min => "1 hr"
    # 10 min => "10 min"
    seconds = duration_seconds(scope)
    hours = seconds / 3600
    minutes = (seconds % 3600) / 60

    if hours > 1
      "#{hours} hrs"
    elsif hours == 1
      "1 hr"
    elsif minutes > 0
      "#{minutes} min"
    else
      "0 min"
    end
  end

  def self.daily_durations(start_date: 365.days.ago, end_date: Time.current)
    select(Arel.sql("DATE_TRUNC('day', time) as day_group"))
      .where(time: start_date..end_date)
      .group("day_group")
      .duration_seconds
      .map { |date, duration| [ date.to_date, duration ] }
  end
end
