class UsersController < ApplicationController
  before_action :set_user
  before_action :require_current_user
  before_action :require_admin, unless: :is_own_settings?

  def edit
    @can_enable_slack_status = @user.slack_access_token.present? && @user.slack_scopes.include?("users.profile:write")
  end

  def update
    if @user.update(user_params)
      if @user.uses_slack_status?
        @user.update_slack_status
      end
      redirect_to is_own_settings? ? my_settings_path : user_settings_path(@user),
        notice: "Settings updated successfully"
    else
      render :settings, status: :unprocessable_entity
    end
  end

  private

  def require_admin
    unless current_user.admin?
      redirect_to root_path, alert: "You are not authorized to access this page"
    end
  end

  def require_current_user
    unless @user == current_user
      redirect_to root_path, alert: "You are not authorized to access this page"
    end
  end

  def set_user
    @user = if params[:id]
      User.find_by!(slack_uid: params[:id])
    else
      current_user
    end

    redirect_to root_path, alert: "You need to log in!" if @user.nil?
  end

  def is_own_settings?
    @is_own_settings ||= !params[:id].present?
  end

  def user_params
    params.require(:user).permit(:uses_slack_status)
  end
end
