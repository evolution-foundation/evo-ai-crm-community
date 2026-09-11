"""
Pipeline Manipulation Tool

This tool allows agents to manage pipeline items, move contacts through stages,
and create/manage tasks within the pipeline.
"""

from typing import Optional, Dict, Any, List
from google.adk.tools import FunctionTool, ToolContext
from src.services.adk.tools.evo_crm.base import EvoCrmClient
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def _extract_conversation_id_from_metadata(tool_context: Optional[ToolContext]) -> Optional[str]:
    """Extract conversation_id from tool_context metadata."""
    if not tool_context or not hasattr(tool_context, 'state'):
        return None

    state = tool_context.state
    evoai_crm_data = state.get("evoai_crm_data", {})
    if isinstance(evoai_crm_data, dict):
        conversation_id = evoai_crm_data.get("conversation_id")
        if conversation_id:
            return str(conversation_id)

        conversation = evoai_crm_data.get("conversation", {})
        if isinstance(conversation, dict):
            conv_id = conversation.get("id")
            if conv_id:
                return str(conv_id)

    for key in ["conversation_id", "conversationId"]:
        if key in state:
            return str(state[key])

    return None


def _extract_contact_id_from_metadata(tool_context: Optional[ToolContext]) -> Optional[str]:
    """Extract contact_id from tool_context metadata."""
    if not tool_context or not hasattr(tool_context, 'state'):
        return None

    state = tool_context.state
    contact = state.get("contact")
    if isinstance(contact, dict) and contact.get("id"):
        return str(contact.get("id"))

    evoai_crm_data = state.get("evoai_crm_data", {})
    if isinstance(evoai_crm_data, dict):
        contact_data = evoai_crm_data.get("contact", {})
        if isinstance(contact_data, dict) and contact_data.get("id"):
            return str(contact_data.get("id"))

        contact_id = evoai_crm_data.get("contactId") or evoai_crm_data.get("contact_id")
        if contact_id:
            return str(contact_id)

    contact_id = state.get("contactId") or state.get("contact_id")
    if contact_id:
        return str(contact_id)

    return None


def _extract_pipeline_rules_from_metadata(tool_context: Optional[ToolContext]) -> List[Dict[str, Any]]:
    """Extract pipeline_rules from tool_context metadata."""
    if not tool_context or not hasattr(tool_context, 'state'):
        return []

    state = tool_context.state
    agent_config = state.get("agent_config", {})
    if isinstance(agent_config, dict):
        pipeline_rules = agent_config.get("pipeline_rules", [])
        if pipeline_rules:
            return pipeline_rules if isinstance(pipeline_rules, list) else []

    return []


def create_pipeline_manipulation_tool(
    pipeline_rules: Optional[List[Dict[str, Any]]] = None
) -> FunctionTool:
    """Create the pipeline_manipulation tool for managing pipeline items and tasks.

    This tool allows agents to:
    - Add contacts to pipelines
    - Move contacts between pipeline stages
    - Create tasks for pipeline items
    - Update and complete tasks

    Args:
        pipeline_rules: Optional list of pipeline rules from agent config.
                       Each rule should have: pipelineId, pipelineName, stages, allowTasks, allowServices, etc.
    """

    client = EvoCrmClient()
    default_pipeline_rules = pipeline_rules or []

    # The docstring below is REPLACED at the end of this factory; the rewritten
    # one is what becomes the schema the model reads.
    async def pipeline_manipulation(
        action: str,
        contact_id: Optional[str] = None,
        conversation_id: Optional[str] = None,
        pipeline_id: Optional[str] = None,
        stage_id: Optional[str] = None,
        stage_name: Optional[str] = None,
        notes: Optional[str] = None,
        task_title: Optional[str] = None,
        task_description: Optional[str] = None,
        task_type: Optional[str] = None,
        task_due_date: Optional[str] = None,
        task_priority: Optional[str] = None,
        task_id: Optional[str] = None,
        custom_fields: Optional[Dict[str, Any]] = None,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """Manage pipeline items, stages, and tasks.

        Use this tool to:
        1. Add contacts to pipelines (action='add_to_pipeline')
        2. Move contacts between stages (action='move_to_stage')
        3. Create tasks for pipeline items (action='create_task')
        4. Update tasks (action='update_task')
        5. Complete tasks (action='complete_task')

        Pipeline Rules:
        If pipeline_rules are configured in the agent, they define which pipelines
        are available and what actions are allowed for each pipeline.

        Each rule has:
        - pipelineId: ID of the pipeline
        - pipelineName: Name of the pipeline
        - stages: List of stages with stageId, stageName, and instructions
        - allowTasks: Whether tasks can be created
        - allowServices: Whether services can be managed
        - generalInstructions: General guidelines for this pipeline

        Args:
            action: The action to perform:
                   - 'add_to_pipeline': Add contact/conversation to a pipeline
                   - 'move_to_stage': Move to a different pipeline stage
                   - 'create_task': Create a new task
                   - 'update_task': Update an existing task
                   - 'complete_task': Mark a task as completed
            contact_id: DO NOT SET. The conversation context supplies it and
                   overrides anything passed here.
            conversation_id: DO NOT SET. The conversation context supplies it and
                   overrides anything passed here.
            pipeline_id: ID of the pipeline (optional if only one pipeline is configured)
            stage_id: ID of the stage to move to (for move_to_stage, use stage_id OR stage_name)
            stage_name: Name of the stage to move to (alternative to stage_id, e.g. "Em Progresso")
            notes: Optional notes for the action
            task_title: Title for the task (required for create_task)
            task_description: Description for the task (optional)
            task_type: Type of task (optional): 'call', 'email', 'meeting', 'follow_up', 'other'
            task_due_date: Due date for the task in ISO format (YYYY-MM-DD) (optional)
            task_priority: Priority of the task (optional): 'low', 'medium', 'high', 'urgent'
            task_id: ID of the task to update/complete (required for update_task and complete_task)
            custom_fields: Custom fields to update (optional)
            tool_context: The tool context containing session information (automatically provided)

        Returns:
            Dictionary with action status and details:
            {
                "status": "success" | "error",
                "message": "Human-readable message",
                "action": "action_performed",
                "details": {...}
            }
        """
        try:
            # CRM-237: the conversation/contact of a turn is a fact of the context, not a
            # model choice — the prompt already promises the id is auto-extracted. Metadata
            # wins; the model's argument only stands when the context is silent.
            context_contact_id = _extract_contact_id_from_metadata(tool_context) if tool_context else None
            context_conversation_id = _extract_conversation_id_from_metadata(tool_context) if tool_context else None

            effective_contact_id = context_contact_id or contact_id
            if context_contact_id:
                if contact_id and contact_id != context_contact_id:
                    logger.warning(
                        f"[CRM-237] ignoring contact_id={contact_id!r} from the model; "
                        f"the conversation's contact is {context_contact_id}"
                    )
                logger.info(f"Extracted contact_id from metadata: {effective_contact_id}")

            effective_conversation_id = context_conversation_id or conversation_id
            if context_conversation_id:
                if conversation_id and conversation_id != context_conversation_id:
                    logger.warning(
                        f"[CRM-237] ignoring conversation_id={conversation_id!r} from the model; "
                        f"the current conversation is {context_conversation_id}"
                    )
                logger.info(f"Extracted conversation_id from metadata: {effective_conversation_id}")

            # Get pipeline_rules from tool context if not provided during tool creation
            available_pipeline_rules = default_pipeline_rules
            if not available_pipeline_rules and tool_context:
                available_pipeline_rules = _extract_pipeline_rules_from_metadata(tool_context)

            # Determine pipeline_id if not provided
            effective_pipeline_id = pipeline_id
            if not effective_pipeline_id and available_pipeline_rules:
                if len(available_pipeline_rules) == 1:
                    effective_pipeline_id = available_pipeline_rules[0].get("pipelineId")
                    logger.info(f"Using default pipeline from rules: {effective_pipeline_id}")
                elif len(available_pipeline_rules) > 1:
                    return {
                        "status": "error",
                        "message": f"Multiple pipelines configured. Please specify pipeline_id. Available pipelines: {', '.join([r.get('pipelineName', 'Unknown') for r in available_pipeline_rules])}",
                        "action": action,
                    }

            if not effective_pipeline_id:
                return {
                    "status": "error",
                    "message": "pipeline_id is required. No pipeline_rules configured or pipeline_id not provided.",
                    "action": action,
                }

            # Execute the requested action
            if action == 'add_to_pipeline':
                return await _add_to_pipeline(
                    client=client,
                    pipeline_id=effective_pipeline_id,
                    contact_id=effective_contact_id,
                    conversation_id=effective_conversation_id,
                    stage_id=stage_id,
                    custom_fields=custom_fields,
                    pipeline_rules=available_pipeline_rules,
                )

            elif action == 'move_to_stage':
                return await _move_to_stage(
                    client=client,
                    pipeline_id=effective_pipeline_id,
                    conversation_id=effective_conversation_id,
                    stage_id=stage_id,
                    notes=notes,
                    pipeline_rules=available_pipeline_rules,
                    stage_name=stage_name,
                )

            elif action == 'create_task':
                return await _create_task(
                    client=client,
                    pipeline_id=effective_pipeline_id,
                    conversation_id=effective_conversation_id,
                    task_title=task_title,
                    task_description=task_description,
                    task_type=task_type,
                    task_due_date=task_due_date,
                    task_priority=task_priority,
                    pipeline_rules=available_pipeline_rules,
                )

            elif action == 'update_task':
                return await _update_task(
                    client=client,
                    pipeline_id=effective_pipeline_id,
                    task_id=task_id,
                    task_title=task_title,
                    task_description=task_description,
                    task_type=task_type,
                    task_due_date=task_due_date,
                    task_priority=task_priority,
                )

            elif action == 'complete_task':
                return await _complete_task(
                    client=client,
                    pipeline_id=effective_pipeline_id,
                    task_id=task_id,
                )

            else:
                return {
                    "status": "error",
                    "message": f"Invalid action '{action}'. Supported actions: add_to_pipeline, move_to_stage, create_task, update_task, complete_task",
                    "action": action,
                }

        except Exception as e:
            error_msg = f"Unexpected error in pipeline manipulation: {str(e)}"
            logger.error(error_msg)
            return {
                "status": "error",
                "message": error_msg,
                "action": action,
                "error": str(e),
            }

    # Set function metadata
    pipeline_manipulation.__name__ = "pipeline_manipulation"

    # Build docstring with pipeline rules information
    pipeline_rules_doc = ""
    if default_pipeline_rules:
        pipeline_rules_doc = "\n\nConfigured Pipeline Rules:\n"
        for i, rule in enumerate(default_pipeline_rules, 1):
            pipeline_name = rule.get("pipelineName", "Unknown")
            allow_tasks = rule.get("allowTasks", False)
            allow_services = rule.get("allowServices", False)
            general_instructions = rule.get("generalInstructions", "")

            pipeline_rules_doc += f"  {i}. Pipeline: {pipeline_name}"
            if allow_tasks:
                pipeline_rules_doc += " (Tasks enabled)"
            if allow_services:
                pipeline_rules_doc += " (Services enabled)"
            if general_instructions:
                pipeline_rules_doc += f"\n     Instructions: {general_instructions}"

            stages = rule.get("stages", [])
            if stages:
                pipeline_rules_doc += f"\n     Stages:\n"
                for stage in stages:
                    stage_name = stage.get("stageName", "Unknown")
                    stage_instructions = stage.get("instructions", "")
                    pipeline_rules_doc += f"       - {stage_name}"
                    if stage_instructions:
                        pipeline_rules_doc += f": {stage_instructions}"
                    pipeline_rules_doc += "\n"
            pipeline_rules_doc += "\n"

    pipeline_manipulation.__doc__ = f"""Manage pipeline items, stages, and tasks.

    Use this tool to add contacts to pipelines, move them between stages,
    and create/manage tasks for pipeline items.

    Actions:
    - add_to_pipeline: Add contact/conversation to a pipeline
    - move_to_stage: Move to a different pipeline stage
    - create_task: Create a new task for a pipeline item
    - update_task: Update an existing task
    - complete_task: Mark a task as completed{pipeline_rules_doc}

    Use move_to_stage for a conversation that already has a card in the pipeline
    (the normal case for an ongoing conversation); use add_to_pipeline only for a
    conversation that is not in any pipeline yet.

    Args:
        action: The action to perform
        contact_id: DO NOT SET. Supplied by the conversation context, which
            overrides anything passed here.
        conversation_id: DO NOT SET. Supplied by the conversation context, which
            overrides anything passed here.
        pipeline_id: ID of the pipeline (optional if only one configured)
        stage_id: ID of the stage (required for move_to_stage)
        notes: Optional notes
        task_title: Title for tasks (required for create_task)
        task_description: Description for tasks
        task_type: Type of task ('call', 'email', 'meeting', 'follow_up', 'other')
        task_due_date: Due date in ISO format (YYYY-MM-DD)
        task_priority: Priority ('low', 'medium', 'high', 'urgent')
        task_id: ID of task to update/complete
        custom_fields: Custom fields to update

    Returns:
        Dictionary with action status and details
    """

    return FunctionTool(func=pipeline_manipulation)


async def _add_to_pipeline(
    client: EvoCrmClient,
    pipeline_id: str,
    contact_id: Optional[str],
    conversation_id: Optional[str],
    stage_id: Optional[str],
    custom_fields: Optional[Dict[str, Any]],
    pipeline_rules: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Add contact or conversation to a pipeline."""

    # Find pipeline rule
    pipeline_rule = next((r for r in pipeline_rules if r.get("pipelineId") == pipeline_id), None)

    # Determine what to add (contact or conversation)
    if not contact_id and not conversation_id:
        return {
            "status": "error",
            "message": "No contact or conversation in context: this tool only runs inside a conversation.",
            "action": "add_to_pipeline",
        }

    # Prepare request body
    request_body: Dict[str, Any] = {}

    if conversation_id:
        request_body["type"] = "conversation"
        request_body["item_id"] = conversation_id
    elif contact_id:
        request_body["type"] = "contact"
        request_body["item_id"] = contact_id

    # Use provided stage_id or get the first stage from rules
    if stage_id:
        request_body["pipeline_stage_id"] = stage_id
    elif pipeline_rule and pipeline_rule.get("stages"):
        first_stage = pipeline_rule["stages"][0]
        request_body["pipeline_stage_id"] = first_stage.get("stageId")
        logger.info(f"Using first stage from pipeline rules: {first_stage.get('stageName')}")

    if custom_fields:
        request_body["custom_fields"] = custom_fields

    logger.info(
        f"Adding {request_body['type']} {request_body['item_id']} to pipeline {pipeline_id}"
    )

    try:
        endpoint = f"/pipelines/{pipeline_id}/pipeline_items"
        response = await client.post(
            endpoint=endpoint,
            json_data=request_body,
        )

        logger.info(f"Successfully added to pipeline {pipeline_id}")

        pipeline_name = pipeline_rule.get("pipelineName", pipeline_id) if pipeline_rule else pipeline_id

        return {
            "status": "success",
            "message": f"Successfully added to pipeline '{pipeline_name}'",
            "action": "add_to_pipeline",
            "pipeline_id": pipeline_id,
            "details": response,
        }

    except Exception as api_error:
        error_message = str(api_error)

        if "already in this pipeline" in error_message.lower():
            error_message = f"Contact is already in this pipeline. Use 'move_to_stage' to change stages."
        elif "404" in error_message or "not found" in error_message.lower():
            error_message = f"Pipeline or contact not found. Please verify the IDs."

        logger.error(f"Failed to add to pipeline: {error_message}")

        return {
            "status": "error",
            "message": error_message,
            "action": "add_to_pipeline",
            "error": str(api_error),
        }


async def _move_to_stage(
    client: EvoCrmClient,
    pipeline_id: str,
    conversation_id: Optional[str],
    stage_id: Optional[str],
    notes: Optional[str],
    pipeline_rules: List[Dict[str, Any]],
    stage_name: Optional[str] = None,
) -> Dict[str, Any]:
    """Move a contact to a different pipeline stage."""

    if not conversation_id:
        return {
            "status": "error",
            "message": "No conversation in context: this tool only runs inside a conversation.",
            "action": "move_to_stage",
        }

    # Resolve stage_id from stage_name if not provided directly
    if not stage_id and stage_name and pipeline_rules:
        pipeline_rule = next((r for r in pipeline_rules if r.get("pipelineId") == pipeline_id), None)
        if pipeline_rule:
            for s in pipeline_rule.get("stages", []):
                if s.get("stageName", "").lower().strip() == stage_name.lower().strip():
                    stage_id = s.get("stageId")
                    logger.info(f"Resolved stage_id from name '{stage_name}': {stage_id}")
                    break

    if not stage_id:
        # List available stages for the user
        pipeline_rule = next((r for r in pipeline_rules if r.get("pipelineId") == pipeline_id), None)
        available = ", ".join([s.get("stageName", "?") for s in pipeline_rule.get("stages", [])]) if pipeline_rule else "none"
        return {
            "status": "error",
            "message": f"stage_id or stage_name is required. Available stages: {available}",
            "action": "move_to_stage",
        }

    # Find pipeline and stage names from rules
    pipeline_rule = next((r for r in pipeline_rules if r.get("pipelineId") == pipeline_id), None)
    stage_name = "unknown stage"
    if pipeline_rule:
        stage = next((s for s in pipeline_rule.get("stages", []) if s.get("stageId") == stage_id), None)
        if stage:
            stage_name = stage.get("stageName", stage_name)

    logger.info(
        f"Moving conversation {conversation_id} to stage {stage_id} in pipeline {pipeline_id}"
    )

    try:
        endpoint = f"/pipelines/{pipeline_id}/pipeline_items/{conversation_id}/move_to_stage"
        request_body = {
            "new_stage_id": stage_id,
        }

        if notes:
            request_body["notes"] = notes

        response = await client.patch(
            endpoint=endpoint,
            json_data=request_body,
        )

        logger.info(f"Successfully moved to stage {stage_id}")

        return {
            "status": "success",
            "message": f"Successfully moved to stage '{stage_name}'",
            "action": "move_to_stage",
            "pipeline_id": pipeline_id,
            "stage_id": stage_id,
            "stage_name": stage_name,
            "details": response,
        }

    except Exception as api_error:
        error_message = str(api_error)

        if "404" in error_message or "not found" in error_message.lower():
            error_message = f"Conversation not found in pipeline or stage not found. Make sure the contact is already in the pipeline (use 'add_to_pipeline' first)."

        logger.error(f"Failed to move to stage: {error_message}")

        return {
            "status": "error",
            "message": error_message,
            "action": "move_to_stage",
            "error": str(api_error),
        }


async def _create_task(
    client: EvoCrmClient,
    pipeline_id: str,
    conversation_id: Optional[str],
    task_title: Optional[str],
    task_description: Optional[str],
    task_type: Optional[str],
    task_due_date: Optional[str],
    task_priority: Optional[str],
    pipeline_rules: List[Dict[str, Any]],
) -> Dict[str, Any]:
    """Create a task for a pipeline item."""

    if not conversation_id:
        return {
            "status": "error",
            "message": "No conversation in context: this tool only runs inside a conversation.",
            "action": "create_task",
        }

    if not task_title:
        return {
            "status": "error",
            "message": "task_title is required to create a task.",
            "action": "create_task",
        }

    # Check if tasks are allowed for this pipeline
    pipeline_rule = next((r for r in pipeline_rules if r.get("pipelineId") == pipeline_id), None)
    if pipeline_rule and not pipeline_rule.get("allowTasks", False):
        return {
            "status": "error",
            "message": f"Tasks are not enabled for pipeline '{pipeline_rule.get('pipelineName', pipeline_id)}'.",
            "action": "create_task",
        }

    # Get the pipeline_item_id from conversation_id
    # We need to find the pipeline_item that matches this conversation in this pipeline
    try:
        # First, get pipeline items to find the matching one
        items_endpoint = f"/pipelines/{pipeline_id}/pipeline_items"
        items_response = await client.get(
            endpoint=items_endpoint,
        )

        # Find the pipeline item for this conversation
        pipeline_item_id = None
        if isinstance(items_response, dict):
            items = items_response.get("payload", [])
            for item in items:
                if item.get("conversation_id") == conversation_id:
                    pipeline_item_id = item.get("id")
                    break

        if not pipeline_item_id:
            return {
                "status": "error",
                "message": f"Conversation not found in pipeline. Make sure to add the contact to the pipeline first using 'add_to_pipeline'.",
                "action": "create_task",
            }

    except Exception as e:
        logger.error(f"Failed to find pipeline item: {str(e)}")
        return {
            "status": "error",
            "message": f"Failed to find pipeline item for conversation. Error: {str(e)}",
            "action": "create_task",
        }

    logger.info(
        f"Creating task '{task_title}' for pipeline item {pipeline_item_id}"
    )

    try:
        endpoint = f"/pipelines/{pipeline_id}/pipeline_items/{pipeline_item_id}/tasks"
        request_body = {
            "task": {
                "title": task_title,
            }
        }

        if task_description:
            request_body["task"]["description"] = task_description
        if task_type:
            request_body["task"]["task_type"] = task_type
        if task_due_date:
            request_body["task"]["due_date"] = task_due_date
        if task_priority:
            request_body["task"]["priority"] = task_priority

        response = await client.post(
            endpoint=endpoint,
            json_data=request_body,
        )

        logger.info(f"Successfully created task '{task_title}'")

        return {
            "status": "success",
            "message": f"Successfully created task '{task_title}'",
            "action": "create_task",
            "pipeline_id": pipeline_id,
            "task_title": task_title,
            "details": response,
        }

    except Exception as api_error:
        error_message = str(api_error)

        if "404" in error_message or "not found" in error_message.lower():
            error_message = f"Pipeline item not found. Make sure the contact is in the pipeline."

        logger.error(f"Failed to create task: {error_message}")

        return {
            "status": "error",
            "message": error_message,
            "action": "create_task",
            "error": str(api_error),
        }


async def _update_task(
    client: EvoCrmClient,
    pipeline_id: str,
    task_id: Optional[str],
    task_title: Optional[str],
    task_description: Optional[str],
    task_type: Optional[str],
    task_due_date: Optional[str],
    task_priority: Optional[str],
) -> Dict[str, Any]:
    """Update an existing task."""

    if not task_id:
        return {
            "status": "error",
            "message": "task_id is required to update a task.",
            "action": "update_task",
        }

    logger.info(f"Updating task {task_id}")

    try:
        endpoint = f"/pipelines/{pipeline_id}/tasks/{task_id}"
        request_body = {"task": {}}

        if task_title:
            request_body["task"]["title"] = task_title
        if task_description:
            request_body["task"]["description"] = task_description
        if task_type:
            request_body["task"]["task_type"] = task_type
        if task_due_date:
            request_body["task"]["due_date"] = task_due_date
        if task_priority:
            request_body["task"]["priority"] = task_priority

        if not request_body["task"]:
            return {
                "status": "error",
                "message": "At least one field must be provided to update the task.",
                "action": "update_task",
            }

        response = await client.put(
            endpoint=endpoint,
            json_data=request_body,
        )

        logger.info(f"Successfully updated task {task_id}")

        return {
            "status": "success",
            "message": f"Successfully updated task",
            "action": "update_task",
            "task_id": task_id,
            "details": response,
        }

    except Exception as api_error:
        error_message = str(api_error)

        if "404" in error_message or "not found" in error_message.lower():
            error_message = f"Task not found."

        logger.error(f"Failed to update task: {error_message}")

        return {
            "status": "error",
            "message": error_message,
            "action": "update_task",
            "error": str(api_error),
        }


async def _complete_task(
    client: EvoCrmClient,
    pipeline_id: str,
    task_id: Optional[str],
) -> Dict[str, Any]:
    """Mark a task as completed."""

    if not task_id:
        return {
            "status": "error",
            "message": "task_id is required to complete a task.",
            "action": "complete_task",
        }

    logger.info(f"Completing task {task_id}")

    try:
        endpoint = f"/pipelines/{pipeline_id}/tasks/{task_id}/complete"

        response = await client.post(
            endpoint=endpoint,
            json_data={},
        )

        logger.info(f"Successfully completed task {task_id}")

        return {
            "status": "success",
            "message": f"Successfully completed task",
            "action": "complete_task",
            "task_id": task_id,
            "details": response,
        }

    except Exception as api_error:
        error_message = str(api_error)

        if "404" in error_message or "not found" in error_message.lower():
            error_message = f"Task not found."

        logger.error(f"Failed to complete task: {error_message}")

        return {
            "status": "error",
            "message": error_message,
            "action": "complete_task",
            "error": str(api_error),
        }
