"""
Transfer to Human Tool

This tool allows agents to transfer conversations to human agents,
following transfer rules and best practices.
"""

from typing import Optional, Dict, Any, List
from google.adk.tools import FunctionTool, ToolContext
from src.services.adk.tools.evo_crm.base import EvoCrmClient
from src.utils.logger import setup_logger

logger = setup_logger(__name__)


def _extract_conversation_id_from_metadata(tool_context: Optional[ToolContext]) -> Optional[str]:
    """Extract conversation_id from tool_context metadata.
    
    Looks for conversation_id in various possible locations:
    - evoai_crm_data.conversation_id (UUID)
    - evoai_crm_data.conversation.id (display_id)
    - conversation_id (direct)
    - conversationId (camelCase)
    """
    if not tool_context or not hasattr(tool_context, 'state'):
        return None
    
    state = tool_context.state
    
    # Try evoai_crm_data
    evoai_crm_data = state.get("evoai_crm_data", {})
    if isinstance(evoai_crm_data, dict):
        # Try conversation_id (UUID)
        conversation_id = evoai_crm_data.get("conversation_id")
        if conversation_id:
            return str(conversation_id)
        
        # Try conversation.id (display_id)
        conversation = evoai_crm_data.get("conversation", {})
        if isinstance(conversation, dict):
            conv_id = conversation.get("id")
            if conv_id:
                return str(conv_id)
    
    # Try direct keys
    for key in ["conversation_id", "conversationId"]:
        if key in state:
            return str(state[key])
    
    return None


def _extract_transfer_rules_from_metadata(tool_context: Optional[ToolContext]) -> List[Dict[str, Any]]:
    """Extract transfer_rules from tool_context metadata."""
    if not tool_context or not hasattr(tool_context, 'state'):
        return []
    
    state = tool_context.state
    
    # Try to get transfer_rules from agent config in state
    agent_config = state.get("agent_config", {})
    if isinstance(agent_config, dict):
        transfer_rules = agent_config.get("transfer_rules", [])
        if transfer_rules:
            return transfer_rules if isinstance(transfer_rules, list) else []
    
    return []


def create_transfer_to_human_tool(
    transfer_rules: Optional[List[Dict[str, Any]]] = None
) -> FunctionTool:
    """Create the transfer_to_human tool for transferring conversations to human agents.

    This tool transfers a conversation to a human agent, following transfer rules
    and considering agent availability and workload.

    Args:
        transfer_rules: Optional list of transfer rules from agent config.
                       Each rule should have: transferTo, userId, teamId, instructions, etc.
    """
    
    client = EvoCrmClient()
    default_transfer_rules = transfer_rules or []
    
    async def transfer_to_human(
        assignee_id: Optional[str] = None,
        conversation_id: Optional[str] = None,
        team_id: Optional[str] = None,
        reason: Optional[str] = None,
        tool_context: Optional[ToolContext] = None,
    ) -> Dict[str, Any]:
        """Transfer a conversation to a human agent.
        
        Use this tool when:
        - The user explicitly requests to speak with a human agent
        - The conversation requires human expertise beyond the AI's capabilities
        - The user is frustrated or dissatisfied with automated responses
        - Complex issues require human judgment and empathy
        - The conversation involves sensitive topics that need human handling
        - Escalation is needed based on predefined transfer rules
        
        Transfer Rules:
        If transfer_rules are configured in the agent, use them to determine who to transfer to.
        Each rule has:
        - transferTo: "human" or "team"
        - userId: ID of the user to transfer to (if transferTo is "human")
        - teamId: ID of the team to transfer to (if transferTo is "team")
        - instructions: When to use this rule (e.g., "quando o contato pedir")
        
        If no transfer_rules are configured, you must provide assignee_id or team_id.
        
    Args:
        assignee_id: The ID of the human agent to assign the conversation to (optional if transfer_rules are configured)
        conversation_id: The ID of the conversation to transfer (optional,
                        will be automatically extracted from conversation context)
        team_id: Optional team ID to assign the conversation to a team instead (optional if transfer_rules are configured)
        reason: Optional reason for the transfer (for logging and context)
        tool_context: The tool context containing session information (automatically provided)
            
        Returns:
            Dictionary with transfer status and details:
            {
                "status": "success" | "error",
                "message": "Human-readable message",
                "conversation_id": "...",
                "assignee_id": "...",
                "details": {...}
            }
        """
        try:
            # Extract conversation_id from metadata if not provided
            effective_conversation_id = conversation_id
            if not effective_conversation_id and tool_context:
                effective_conversation_id = _extract_conversation_id_from_metadata(tool_context)
                if effective_conversation_id:
                    logger.info(f"Extracted conversation_id from metadata: {effective_conversation_id}")
            
            # Validate required parameters
            if not effective_conversation_id:
                return {
                    "status": "error",
                    "message": "conversation_id is required. It should be automatically extracted from the conversation context, but if not available, please provide it explicitly.",
                    "conversation_id": None,
                }
            
            # Get transfer_rules from tool context if not provided during tool creation
            available_transfer_rules = default_transfer_rules
            if not available_transfer_rules and tool_context:
                available_transfer_rules = _extract_transfer_rules_from_metadata(tool_context)
            
            # Determine assignee_id and team_id from transfer_rules if not provided
            effective_assignee_id = assignee_id
            effective_team_id = team_id
            
            if not effective_assignee_id and not effective_team_id and available_transfer_rules:
                # Use the first transfer rule that matches "human" or "team"
                # In the future, this could be enhanced to evaluate rule conditions
                for rule in available_transfer_rules:
                    if rule.get("transferTo") == "human" and rule.get("userId"):
                        effective_assignee_id = rule.get("userId")
                        logger.info(f"Using transfer rule to assign to user {effective_assignee_id}")
                        if rule.get("instructions"):
                            reason = reason or rule.get("instructions")
                        break
                    elif rule.get("transferTo") == "team" and rule.get("teamId"):
                        effective_team_id = rule.get("teamId")
                        logger.info(f"Using transfer rule to assign to team {effective_team_id}")
                        if rule.get("instructions"):
                            reason = reason or rule.get("instructions")
                        break
            
            # Validate that we have either assignee_id or team_id
            if not effective_assignee_id and not effective_team_id:
                return {
                    "status": "error",
                    "message": "Either assignee_id or team_id is required. If transfer_rules are configured, they will be used automatically. Otherwise, please provide assignee_id or team_id explicitly.",
                    "conversation_id": effective_conversation_id,
                }
            
            logger.info(
                f"Transferring conversation {effective_conversation_id} to agent {effective_assignee_id}"
                + (f" (team: {effective_team_id})" if effective_team_id else "")
                + (f" - Reason: {reason}" if reason else "")
            )
            
            # Prepare request body
            request_body: Dict[str, Any] = {}
            
            if effective_assignee_id:
                request_body["assignee_id"] = effective_assignee_id
            
            if effective_team_id:
                request_body["team_id"] = effective_team_id
            
            # Make API request to assign conversation
            endpoint = f"/conversations/{effective_conversation_id}/assignments"
            
            try:
                response = await client.post(
                    endpoint=endpoint,
                    json_data=request_body,
                )

                # After successful assignment, change conversation status to 'open' if it's 'pending'
                # This ensures the conversation is visible to human agents
                try:
                    status_endpoint = f"/conversations/{effective_conversation_id}/toggle_status"
                    await client.post(
                        endpoint=status_endpoint,
                        json_data={"status": "open"},
                    )
                    logger.info(f"Changed conversation {effective_conversation_id} status to 'open' after transfer")
                except Exception as status_error:
                    # Log but don't fail the transfer if status update fails
                    logger.warning(f"Failed to update conversation status after transfer: {status_error}")
                
                logger.info(
                    f"Successfully transferred conversation {effective_conversation_id} to agent {effective_assignee_id}"
                    + (f" (team: {effective_team_id})" if effective_team_id else "")
                )
                
                # Extract assignee info from response if available
                assignee_name = None
                if isinstance(response, dict):
                    assignee_name = response.get("name") or response.get("full_name")
                
                success_message = (
                    f"Conversation {effective_conversation_id} successfully transferred"
                    + (f" to {assignee_name}" if assignee_name else f" to agent {effective_assignee_id}" if effective_assignee_id else "")
                    + (f" (team: {effective_team_id})" if effective_team_id else "")
                )
                
                if reason:
                    success_message += f". Reason: {reason}"
                
                return {
                    "status": "success",
                    "message": success_message,
                    "conversation_id": effective_conversation_id,
                    "assignee_id": effective_assignee_id,
                    "team_id": effective_team_id,
                    "reason": reason,
                    "details": response,
                }
                
            except Exception as api_error:
                error_message = str(api_error)
                
                # Provide more specific error messages
                if "404" in error_message or "not found" in error_message.lower():
                    error_message = (
                        f"Conversation {effective_conversation_id} or agent {effective_assignee_id} not found. "
                        "Please verify the IDs are correct."
                    )
                elif "401" in error_message or "unauthorized" in error_message.lower():
                    error_message = (
                        "Authentication failed. Please check EVOAI_CRM_API_TOKEN configuration."
                    )
                elif "400" in error_message or "bad request" in error_message.lower():
                    error_message = (
                        f"Invalid request. Please check conversation_id ({effective_conversation_id}) "
                        f"and assignee_id ({effective_assignee_id}) are valid UUIDs."
                    )
                
                logger.error(f"Failed to transfer conversation: {error_message}")
                
                return {
                    "status": "error",
                    "message": error_message,
                    "conversation_id": effective_conversation_id,
                    "assignee_id": effective_assignee_id,
                    "error": str(api_error),
                }
                
        except Exception as e:
            error_msg = f"Unexpected error transferring conversation: {str(e)}"
            logger.error(error_msg)
            return {
                "status": "error",
                "message": error_msg,
                "conversation_id": effective_conversation_id if 'effective_conversation_id' in locals() else None,
                "assignee_id": effective_assignee_id if 'effective_assignee_id' in locals() else None,
                "error": str(e),
            }
    
    # Set function metadata for better tool description
    transfer_to_human.__name__ = "transfer_to_human"
    
    # Build docstring with transfer rules information
    transfer_rules_doc = ""
    if default_transfer_rules:
        transfer_rules_doc = "\n\nConfigured Transfer Rules:\n"
        for i, rule in enumerate(default_transfer_rules, 1):
            transfer_to = rule.get("transferTo", "unknown")
            instructions = rule.get("instructions", "")
            if transfer_to == "human":
                user_name = rule.get("userName", rule.get("userId", "unknown"))
                transfer_rules_doc += f"  {i}. Transfer to human: {user_name}"
            elif transfer_to == "team":
                team_name = rule.get("teamName", rule.get("teamId", "unknown"))
                transfer_rules_doc += f"  {i}. Transfer to team: {team_name}"
            if instructions:
                transfer_rules_doc += f" ({instructions})"
            transfer_rules_doc += "\n"
    
    transfer_to_human.__doc__ = f"""Transfer a conversation to a human agent.
    
    Use this tool when the user requests human assistance, when complex issues require
    human expertise, or when escalation is needed based on transfer rules.
    
    If transfer_rules are configured, they will be used automatically. Otherwise,
    you must provide assignee_id or team_id.{transfer_rules_doc}
    
    Args:
        conversation_id: The ID of the conversation to transfer (optional, auto-extracted)
        assignee_id: The ID of the human agent to assign to (optional if transfer_rules configured)
        team_id: Optional team ID to assign to a team instead (optional if transfer_rules configured)
        reason: Optional reason for transfer (for logging)
    
    Returns:
        Dictionary with transfer status and details
    """
    
    return FunctionTool(func=transfer_to_human)

