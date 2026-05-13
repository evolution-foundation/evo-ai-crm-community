class TemplatePolicy < ApplicationPolicy
  class Scope
    attr_reader :user_context, :user, :scope, :account

    def initialize(user_context, scope)
      @user_context = user_context
      @user = user_context[:user]
      @account = user_context[:account]
      @scope = scope
    end

    def resolve
      scope.all
    end
  end

  def index?
    @user&.administrator? || @user&.has_permission?('templates.read')
  end

  def export?
    @user&.administrator? || @user&.has_permission?('templates.export')
  end

  def import?
    @user&.administrator? || @user&.has_permission?('templates.import')
  end

  def exportable_inventory?
    export?
  end
end
