"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: models.py                                                             │
│ Developed by: Davidson Gomes                                                 │
│ Creation date: May 13, 2025                                                  │
│ Contact: contato@evolution-api.com                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2025. All rights reserved.                        │
│ Licensed under the Apache License, Version 2.0                               │
│                                                                              │
│ You may not use this file except in compliance with the License.             │
│ You may obtain a copy of the License at                                      │
│                                                                              │
│    http://www.apache.org/licenses/LICENSE-2.0                                │
│                                                                              │
│ Unless required by applicable law or agreed to in writing, software          │
│ distributed under the License is distributed on an "AS IS" BASIS,            │
│ WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.     │
│ See the License for the specific language governing permissions and          │
│ limitations under the License.                                               │
├──────────────────────────────────────────────────────────────────────────────┤
│ @important                                                                   │
│ For any future changes to the code in this file, it is recommended to        │
│ include, together with the modification, the information of the developer    │
│ who changed it and the date of modification.                                 │
└──────────────────────────────────────────────────────────────────────────────┘
"""

import os
from sqlalchemy import (
    Column,
    Integer,
    String,
    Float,
    DateTime,
    ForeignKey,
    JSON,
    Text,
    CheckConstraint,
    Boolean,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.sql import func
from sqlalchemy.orm import relationship
from src.config.database import Base
import uuid

# Plan and Feature Models for Feature Flag System
class Plan(Base):
    """Plan model for subscription management"""
    __tablename__ = "plans"
    __table_args__ = {"info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False, unique=True)
    description = Column(Text)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    # Relationships
    plan_features = relationship("PlanFeature", back_populates="plan")


class Feature(Base):
    """Feature model for feature flag system"""
    __tablename__ = "features"
    __table_args__ = {"info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    key = Column(String, nullable=False, unique=True)
    description = Column(Text)
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    # Relationships
    plan_features = relationship("PlanFeature", back_populates="feature")


class PlanFeature(Base):
    """Plan feature with default values"""
    __tablename__ = "plan_features"
    __table_args__ = {"info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    plan_id = Column(UUID(as_uuid=True), ForeignKey("plans.id"), nullable=False)
    feature_id = Column(UUID(as_uuid=True), ForeignKey("features.id"), nullable=False)
    value = Column(String, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    # Relationships
    plan = relationship("Plan", back_populates="plan_features")
    feature = relationship("Feature", back_populates="plan_features")


class User(Base):
    """
    This definition is only for foreign key references.
    """
    __tablename__ = "users"
    __table_args__ = {"info": {"skip_autogenerate": True}}

    id = Column(Integer, primary_key=True)

class AgentFolder(Base):
    __tablename__ = "evo_core_agent_folders"
    __table_args__ = {"extend_existing": True, "info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    agents = relationship("Agent", back_populates="folder")


class FolderShare(Base):
    __tablename__ = "evo_core_folder_shares"
    __table_args__ = {"extend_existing": True, "info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    folder_id = Column(
        UUID(as_uuid=True),
        ForeignKey("evo_core_agent_folders.id", ondelete="CASCADE"),
        nullable=False,
    )
    shared_by_user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )
    shared_with_email = Column(String, nullable=False)
    shared_with_user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=True,
    )
    permission_level = Column(String, nullable=False, default="read")  # read, write
    is_active = Column(Boolean, default=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    __table_args__ = (
        CheckConstraint(
            "permission_level IN ('read', 'write')",
            name="check_permission_level",
        ),
    )

    folder = relationship("AgentFolder", backref="shares")


class Agent(Base):
    __tablename__ = "evo_core_agents"
    __table_args__ = {"extend_existing": True, "info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    role = Column(String, nullable=True)
    goal = Column(Text, nullable=True)
    description = Column(Text, nullable=True)
    type = Column(String, nullable=False)
    model = Column(String, nullable=True, default="")
    api_key_id = Column(
        UUID(as_uuid=True),
        ForeignKey("evo_core_api_keys.id", ondelete="SET NULL"),
        nullable=True,
    )
    instruction = Column(Text)
    card_url = Column(String, nullable=True)
    folder_id = Column(
        UUID(as_uuid=True),
        ForeignKey("evo_core_agent_folders.id", ondelete="SET NULL"),
        nullable=True,
    )
    config = Column(JSON, default={})
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    __table_args__ = (
        CheckConstraint(
            "type IN ('llm', 'sequential', 'parallel', 'loop', 'a2a', 'workflow', 'crew_ai', 'task', 'external')",
            name="check_agent_type",
        ),
    )

    folder = relationship("AgentFolder", back_populates="agents")

    api_key_ref = relationship("ApiKey", foreign_keys=[api_key_id])

    @property
    def card_url_property(self) -> str:
        """Virtual URL for the agent card"""
        if self.card_url:
            return self.card_url

        return f"{os.getenv('API_URL', '')}/api/v1/a2a/{self.id}/.well-known/agent.json"

    def to_dict(self):
        """Converts the object to a dictionary, converting UUIDs to strings"""
        result = {}
        for key, value in self.__dict__.items():
            if key.startswith("_"):
                continue
            if isinstance(value, uuid.UUID):
                result[key] = str(value)
            elif isinstance(value, dict):
                result[key] = self._convert_dict(value)
            elif isinstance(value, list):
                result[key] = [
                    (
                        self._convert_dict(item)
                        if isinstance(item, dict)
                        else str(item) if isinstance(item, uuid.UUID) else item
                    )
                    for item in value
                ]
            else:
                result[key] = value
        result["card_url"] = self.card_url_property
        return result

    def _convert_dict(self, d):
        """Converts UUIDs to a dictionary for strings"""
        result = {}
        for key, value in d.items():
            if isinstance(value, uuid.UUID):
                result[key] = str(value)
            elif isinstance(value, dict):
                result[key] = self._convert_dict(value)
            elif isinstance(value, list):
                result[key] = [
                    (
                        self._convert_dict(item)
                        if isinstance(item, dict)
                        else str(item) if isinstance(item, uuid.UUID) else item
                    )
                    for item in value
                ]
            else:
                result[key] = value
        return result


class MCPServer(Base):
    __tablename__ = "evo_core_mcp_servers"
    __table_args__ = {"extend_existing": True, "info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    config_type = Column(String, nullable=False, default="studio")
    config_json = Column(JSON, nullable=False, default={})
    environments = Column(JSON, nullable=False, default={})
    tools = Column(JSON, nullable=False, default=[])
    type = Column(String, nullable=False, default="official")
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    __table_args__ = (
        CheckConstraint(
            "type IN ('official', 'community')", name="check_mcp_server_type"
        ),
        CheckConstraint(
            "config_type IN ('studio', 'sse')", name="check_mcp_server_config_type"
        ),
    )


class Session(Base):
    __tablename__ = "evo_ai_agent_processor_sessions"

    id = Column(String, primary_key=True)
    app_name = Column(String)
    user_id = Column(String)
    state = Column(JSON)
    create_time = Column(DateTime(timezone=True))
    update_time = Column(DateTime(timezone=True))


class SessionMetadata(Base):
    __tablename__ = "evo_ai_agent_processor_session_metadata"

    session_id = Column(String, primary_key=True)
    name = Column(String, nullable=True)
    description = Column(Text, nullable=True)
    tags = Column(JSON, nullable=True, default=[])
    created_by_user_id = Column(String)
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())


class CustomMCPServer(Base):
    __tablename__ = "evo_core_custom_mcp_servers"
    __table_args__ = {"info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    url = Column(String, nullable=False)
    headers = Column(JSON, nullable=False, default={})
    # Vault references: header name -> credential id.
    credential_refs = Column(JSON, nullable=False, default={})
    timeout = Column(String, nullable=False, default="30")
    retry_count = Column(String, nullable=False, default="3")
    tags = Column(JSON, nullable=False, default=[])
    tools = Column(JSON, nullable=False, default=[])
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())


class ApiKey(Base):
    __tablename__ = "evo_core_api_keys"
    __table_args__ = {"info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    provider = Column(String, nullable=False)
    key = Column(String, nullable=False)  # Correct column name from database
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())
    is_active = Column(Boolean, default=True)


class CustomTool(Base):
    __tablename__ = "evo_core_custom_tools"
    __table_args__ = {"info": {"skip_autogenerate": True}}

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    name = Column(String, nullable=False)
    description = Column(Text, nullable=True)
    method = Column(String, nullable=False)
    endpoint = Column(String, nullable=False)
    headers = Column(JSON, nullable=False, default={})
    # Vault references: header name -> credential id.
    credential_refs = Column(JSON, nullable=False, default={})
    path_params = Column(JSON, nullable=False, default={})
    query_params = Column(JSON, nullable=False, default={})
    body_params = Column(JSON, nullable=False, default={})
    error_handling = Column(JSON, nullable=False, default={})
    values = Column(JSON, nullable=False, default={})
    tags = Column(JSON, nullable=False, default=[])
    examples = Column(JSON, nullable=False, default=[])
    input_modes = Column(JSON, nullable=False, default=[])
    output_modes = Column(JSON, nullable=False, default=[])
    created_at = Column(DateTime(timezone=True), server_default=func.now())
    updated_at = Column(DateTime(timezone=True), onupdate=func.now())

    __table_args__ = (
        CheckConstraint(
            "method IN ('GET', 'POST', 'PUT', 'DELETE', 'PATCH')",
            name="check_http_method",
        ),
    )


class ExecutionMetrics(Base):
    __tablename__ = "evo_ai_agent_processor_execution_metrics"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    agent_id = Column(UUID(as_uuid=True), ForeignKey("evo_core_agents.id", ondelete="CASCADE"))
    session_id = Column(String, nullable=False)
    user_id = Column(String, nullable=False)
    llm_model = Column(String, nullable=False)
    prompt_tokens = Column(Integer, nullable=False)
    candidate_tokens = Column(Integer, nullable=False)
    cost = Column(Float, nullable=False)
    total_tokens = Column(Integer, nullable=False)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    agent = relationship("Agent", backref="execution_metrics")

