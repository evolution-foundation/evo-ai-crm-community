"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: settings.py                                                           │
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
from typing import Optional, List
from pydantic_settings import BaseSettings
import secrets
from dotenv import load_dotenv

# Load environment variables
load_dotenv()


class Settings(BaseSettings):
    """Project settings"""

    # API settings
    API_TITLE: str = os.getenv("API_TITLE", "Evo AI Agent Processor")
    API_DESCRIPTION: str = os.getenv("API_DESCRIPTION", "Agent Processor for Evo AI")
    API_VERSION: str = os.getenv("API_VERSION", "1.0.0")
    API_URL: str = os.getenv("API_URL", "http://localhost:8000")
    
    # Evolution Configuration
    EVOLUTION_BASE_URL: str = os.getenv("EVOLUTION_BASE_URL", "http://localhost:3000")
    EVO_AUTH_BASE_URL: str = os.getenv("EVO_AUTH_BASE_URL", "http://localhost:3001")
    EVO_CORE_BASE_URL: str = os.getenv("EVO_CORE_BASE_URL", "http://localhost:9001")
    
    # Encryption settings (shared with evo-ai-core-service)
    ENCRYPTION_KEY: str = os.getenv("ENCRYPTION_KEY", "")

    # Organization settings
    ORGANIZATION_NAME: str = os.getenv("ORGANIZATION_NAME", "Evo AI")
    ORGANIZATION_URL: str = os.getenv(
        "ORGANIZATION_URL", "https://evoai.evoapicloud.com"
    )

    # Database settings
    POSTGRES_CONNECTION_STRING: str = os.getenv(
        "POSTGRES_CONNECTION_STRING", "postgresql://postgres:root@localhost:5432/evo_community"
    )

    # AI engine settings
    AI_ENGINE: str = os.getenv("AI_ENGINE", "adk")

    # Logging settings
    LOG_LEVEL: str = os.getenv("LOG_LEVEL", "INFO")
    LOG_DIR: str = "logs"

    # Redis settings
    REDIS_HOST: str = os.getenv("REDIS_HOST", "localhost")
    REDIS_PORT: int = int(os.getenv("REDIS_PORT", 6379))
    REDIS_DB: int = int(os.getenv("REDIS_DB", 0))
    REDIS_PASSWORD: Optional[str] = os.getenv("REDIS_PASSWORD")
    REDIS_SSL: bool = os.getenv("REDIS_SSL", "false").lower() == "true"
    REDIS_KEY_PREFIX: str = os.getenv("REDIS_KEY_PREFIX", "evoai:")
    REDIS_TTL: int = int(os.getenv("REDIS_TTL", 3600))

    # Tool cache settings
    TOOLS_CACHE_TTL: int = int(os.getenv("TOOLS_CACHE_TTL", 3600))
    TOOLS_CACHE_ENABLED: bool = (
        os.getenv("TOOLS_CACHE_ENABLED", "true").lower() == "true"
    )

    # Rate Limiting settings
    RATE_LIMIT_GLOBAL_RPS: float = float(os.getenv("RATE_LIMIT_GLOBAL_RPS", 1000))
    RATE_LIMIT_GLOBAL_BURST: int = int(os.getenv("RATE_LIMIT_GLOBAL_BURST", 50))
    RATE_LIMIT_CLIENT_RPS: float = float(os.getenv("RATE_LIMIT_CLIENT_RPS", 100))
    RATE_LIMIT_CLIENT_BURST: int = int(os.getenv("RATE_LIMIT_CLIENT_BURST", 10))
    RATE_LIMIT_CLEANUP_INTERVAL: int = int(os.getenv("RATE_LIMIT_CLEANUP_INTERVAL", "300"))  # 5 minutes in seconds

    # Health Check settings
    HEALTH_CHECK_TIMEOUT: float = float(os.getenv("HEALTH_CHECK_TIMEOUT", "5.0"))  # 5 seconds
    READINESS_CHECK_TIMEOUT: float = float(os.getenv("READINESS_CHECK_TIMEOUT", "2.0"))  # 2 seconds
    DB_HEALTH_CHECK_QUERY: str = os.getenv("DB_HEALTH_CHECK_QUERY", "SELECT 1")
    DB_CONN_THRESHOLD_DEGRADED: int = int(os.getenv("DB_CONN_THRESHOLD_DEGRADED", 90))
    DB_WAIT_COUNT_THRESHOLD: int = int(os.getenv("DB_WAIT_COUNT_THRESHOLD", 100))
    MEMORY_THRESHOLD_WARNING: int = int(os.getenv("MEMORY_THRESHOLD_WARNING", 400))  # MB
    MEMORY_THRESHOLD_CRITICAL: int = int(os.getenv("MEMORY_THRESHOLD_CRITICAL", 500))  # MB

    # MCP server settings
    MCP_CONNECTION_TIMEOUT: int = int(os.getenv("MCP_CONNECTION_TIMEOUT", 30))
    MCP_DISCOVERY_TIMEOUT: int = int(os.getenv("MCP_DISCOVERY_TIMEOUT", 60))

    # JWT settings
    JWT_SECRET_KEY: str = os.getenv("JWT_SECRET_KEY", secrets.token_urlsafe(32))
    JWT_ALGORITHM: str = os.getenv("JWT_ALGORITHM", "HS256")
    JWT_EXPIRATION_TIME: int = int(os.getenv("JWT_EXPIRATION_TIME", 3600))
                                   
    APP_URL: str = os.getenv("APP_URL", "http://localhost:8000")

    # Server settings
    HOST: str = os.getenv("HOST", "0.0.0.0")
    PORT: int = int(os.getenv("PORT", 8000))
    DEBUG: bool = os.getenv("DEBUG", "false").lower() == "true"

    # Langfuse / OpenTelemetry settings
    LANGFUSE_PUBLIC_KEY: str = os.getenv("LANGFUSE_PUBLIC_KEY", "")
    LANGFUSE_SECRET_KEY: str = os.getenv("LANGFUSE_SECRET_KEY", "")
    OTEL_EXPORTER_OTLP_ENDPOINT: str = os.getenv(
        "OTEL_EXPORTER_OTLP_ENDPOINT", "https://cloud.langfuse.com/api/public/otel"
    )

    # Memory Service Configuration
    # Memory service now uses the knowledge microservice via HTTP
    # All Pinecone/Qdrant/OpenSearch configurations have been removed
    MEMORY_SERVICE_TYPE: str = os.getenv("MEMORY_SERVICE_TYPE", "http")
    MEMORY_ENABLED: bool = os.getenv("MEMORY_ENABLED", "true").lower() == "true"
    MEMORY_MAX_RESULTS: int = int(os.getenv("MEMORY_MAX_RESULTS", 10))

    # Artifact service configuration
    ARTIFACT_SERVICE_TYPE: str = os.getenv(
        "ARTIFACT_SERVICE_TYPE", "auto"
    )  # auto, minio, in_memory

    # Minio settings
    ARTIFACT_ENDPOINT: str = os.getenv("ARTIFACT_ENDPOINT", "localhost:9000")
    ARTIFACT_ACCESS_KEY: str = os.getenv("ARTIFACT_ACCESS_KEY", "minioadmin")
    ARTIFACT_SECRET_KEY: str = os.getenv("ARTIFACT_SECRET_KEY", "minioadmin")
    ARTIFACT_SECURE: bool = os.getenv("ARTIFACT_SECURE", "false").lower() == "true"
    ARTIFACT_REGION: str = os.getenv("ARTIFACT_REGION", "us-east-1")

    # Minio bucket settings
    ARTIFACT_SPEECH_BUCKET: str = os.getenv("ARTIFACT_SPEECH_BUCKET", "speech")
    ARTIFACT_FILES_BUCKET: str = os.getenv("ARTIFACT_FILES_BUCKET", "files")
    ARTIFACT_AUTO_CREATE_BUCKETS: bool = (
        os.getenv("ARTIFACT_AUTO_CREATE_BUCKETS", "true").lower() == "true"
    )

    CORE_SERVICE_URL: str = (
        os.getenv("CORE_SERVICE_URL", "http://localhost:9001/api/v1")
    )

    # Evo AI CRM API settings (for CRM tools)
    EVOAI_CRM_API_TOKEN: Optional[str] = os.getenv("EVOAI_CRM_API_TOKEN")
    EVO_AI_CRM_URL: str = os.getenv("EVO_AI_CRM_URL", "http://localhost:3000")

    class Config:
        env_file = ".env"
        env_file_encoding = "utf-8"
        case_sensitive = True
        extra = "ignore"  # Ignore extra environment variables


def get_settings() -> Settings:
    return Settings()


settings = get_settings()
