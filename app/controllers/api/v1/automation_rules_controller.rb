class Api::V1::AutomationRulesController < Api::V1::BaseController
  include Api::V1::ResourceLimitsHelper

  require_permissions({
    index: 'automation_rules.read',
    show: 'automation_rules.read',
    create: 'automation_rules.create',
    update: 'automation_rules.update',
    destroy: 'automation_rules.delete',
    clone: 'automation_rules.clone'
  })

  before_action :fetch_automation_rule, only: [:show, :update, :destroy, :clone]
  before_action :validate_automation_limit, only: [:create]

  private

  def fetch_automation_rule
    @automation_rule = AutomationRule.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    error_response(
      code: ApiErrorCodes::AUTOMATION_RULE_NOT_FOUND,
      message: "Automation rule with id #{params[:id]} not found",
      status: :not_found
    )
  end

  public

  def index
    @automation_rules = AutomationRule.all

    apply_pagination
    
    paginated_response(
      data: AutomationRuleSerializer.serialize_collection(@automation_rules),
      collection: @automation_rules,
      message: 'Automation rules retrieved successfully'
    )
  end

  def show
    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule retrieved successfully'
    )
  end

  def create
    @automation_rule = AutomationRule.new(automation_rules_permit)
    @automation_rule.actions = params[:actions]
    @automation_rule.conditions = params[:conditions]
    @automation_rule.flow_data = params[:flow_data] if params[:flow_data]

    unless @automation_rule.valid?
      return error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Validation failed',
        details: @automation_rule.errors.full_messages,
        status: :unprocessable_entity
      )
    end

    @automation_rule.save!
    process_attachments
    
    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule created successfully',
      status: :created
    )
  end

  def update
    ActiveRecord::Base.transaction do
      automation_rule_update
      process_attachments
      
      success_response(
        data: AutomationRuleSerializer.serialize(@automation_rule),
        message: 'Automation rule updated successfully'
      )
    rescue StandardError => e
      Rails.logger.error e
      error_response(
        code: ApiErrorCodes::VALIDATION_ERROR,
        message: 'Update failed',
        details: @automation_rule.errors.full_messages,
        status: :unprocessable_entity
      )
    end
  end

  def destroy
    @automation_rule.destroy
    success_response(
      data: { id: @automation_rule.id },
      message: 'Automation rule deleted successfully'
    )
  end

  def clone
    automation_rule = AutomationRule.find_by(id: params[:automation_rule_id])
    new_rule = automation_rule.dup
    new_rule.save!
    @automation_rule = new_rule
    
    success_response(
      data: AutomationRuleSerializer.serialize(@automation_rule),
      message: 'Automation rule cloned successfully',
      status: :created
    )
  end

  def process_attachments
    actions = @automation_rule.actions.filter_map { |k, _v| k if k['action_name'] == 'send_attachment' }
    return if actions.blank?

    actions.each do |action|
      blob_id = action['action_params']
      blob = ActiveStorage::Blob.find_by(id: blob_id)
      @automation_rule.files.attach(blob)
    end
  end

  private

  def automation_rule_update
    @automation_rule.update!(automation_rules_permit)
    @automation_rule.actions = params[:actions] if params[:actions]
    @automation_rule.conditions = params[:conditions] if params[:conditions]
    @automation_rule.flow_data = params[:flow_data] if params[:flow_data]
    @automation_rule.save!
  end

  def automation_rules_permit
    params.permit(
      :name, :description, :event_name, :active, :mode,
      conditions: [:attribute_key, :filter_operator, :query_operator, :custom_attribute_type, { values: [] }],
      actions: [:action_name, { action_params: [] }],
      flow_data: {
        nodes: [
          :id, :type, 
          position: [:x, :y],
          data: {},
          measured: [:width, :height]
        ],
        edges: [
          :id, :source, :target, :sourceHandle, :targetHandle,
          data: {}
        ],
        variables: [
          :id, :name, :type, :default_value,
          data: {}
        ]
      }
    )
  end

  def fetch_automation_rule
    @automation_rule = AutomationRule.find_by(id: params[:id])
  end
end
