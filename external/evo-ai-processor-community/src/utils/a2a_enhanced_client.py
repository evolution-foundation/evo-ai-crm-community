"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: a2a_enhanced_client.py                                                │
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

"""
Enhanced A2A Client that supports both custom implementation and official SDK.

This client provides a unified interface to communicate with A2A agents,
automatically detecting and using the best available implementation.
"""

import logging
import asyncio
import json
from typing import Dict, Any, Optional, AsyncIterator, Union, List
from uuid import uuid4, UUID
from dataclasses import dataclass
from enum import Enum

import httpx

try:
    from a2a.client import A2AClient as SDKClient
    from a2a.types import (
        SendMessageRequest,
        MessageSendParams,
        SendStreamingMessageRequest,
        Message as SDKMessage,
        TextPart as SDKTextPart,
        FilePart as SDKFilePart,
    )

    SDK_AVAILABLE = True
except ImportError:
    SDK_AVAILABLE = False
    logging.warning("a2a-sdk not available for enhanced client")

from src.schemas.a2a_types import (
    Message as CustomMessage,
    Task as CustomTask,
    TaskSendParams as CustomTaskSendParams,
    SendTaskRequest as CustomSendTaskRequest,
    SendTaskStreamingRequest as CustomSendTaskStreamingRequest,
)
from src.schemas.a2a_enhanced_types import (
    A2ATypeValidator,
    convert_to_sdk_format,
    convert_from_sdk_format,
)

logger = logging.getLogger(__name__)


class A2AImplementation(Enum):
    """Tipo de implementação A2A."""

    CUSTOM = "custom"
    SDK = "sdk"
    AUTO = "auto"


@dataclass
class A2AClientConfig:
    """Configuração do cliente A2A."""

    base_url: str
    api_key: str
    implementation: A2AImplementation = A2AImplementation.AUTO
    timeout: int = 30
    custom_headers: Optional[Dict[str, str]] = None


@dataclass
class A2AResponse:
    """Resposta unificada do A2A."""

    success: bool
    data: Optional[Any] = None
    error: Optional[str] = None
    implementation_used: Optional[A2AImplementation] = None
    raw_response: Optional[Any] = None


class EnhancedA2AClient:
    """
    Cliente A2A melhorado que suporta tanto implementação custom quanto SDK oficial.

    Detecta automaticamente a melhor implementação disponível e fornece
    interface unificada para comunicação com agents A2A.
    """

    def __init__(self, config: A2AClientConfig):
        self.config = config
        self.httpx_client = None
        self.sdk_client = None
        self.available_implementations = []
        self._agent_cards_cache = {}

    async def __aenter__(self):
        """Context manager entry."""
        await self.initialize()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        await self.close()

    async def initialize(self):
        """Inicializa o cliente e detecta implementações disponíveis."""
        # Inicializa HTTP client
        headers = {"x-api-key": self.config.api_key, "Content-Type": "application/json"}
        if self.config.custom_headers:
            headers.update(self.config.custom_headers)

        self.httpx_client = httpx.AsyncClient(
            timeout=self.config.timeout, headers=headers
        )

        # Detecta implementações disponíveis
        await self._detect_available_implementations()

        # Inicializa SDK client se disponível
        if A2AImplementation.SDK in self.available_implementations and SDK_AVAILABLE:
            await self._initialize_sdk_client()

    async def close(self):
        """Fecha recursos do cliente."""
        if self.httpx_client:
            await self.httpx_client.aclose()

        if self.sdk_client:
            # SDK client cleanup if needed
            pass

    async def _detect_available_implementations(self):
        """Detecta quais implementações estão disponíveis no servidor."""
        implementations = []

        # Testa implementação custom
        try:
            custom_health_url = f"{self.config.base_url}/api/v1/a2a/health"
            response = await self.httpx_client.get(custom_health_url)
            if response.status_code == 200:
                implementations.append(A2AImplementation.CUSTOM)
                logger.info("Custom A2A implementation detected")
        except Exception as e:
            logger.debug(f"Custom implementation not available: {e}")

        # Testa implementação SDK
        try:
            sdk_health_url = f"{self.config.base_url}/api/v1/a2a-sdk/health"
            response = await self.httpx_client.get(sdk_health_url)
            if response.status_code == 200:
                implementations.append(A2AImplementation.SDK)
                logger.info("SDK A2A implementation detected")
        except Exception as e:
            logger.debug(f"SDK implementation not available: {e}")

        self.available_implementations = implementations
        logger.info(
            f"Available A2A implementations: {[impl.value for impl in implementations]}"
        )

    async def _initialize_sdk_client(self):
        """Inicializa cliente SDK se disponível."""
        if not SDK_AVAILABLE:
            logger.warning("SDK not available for client initialization")
            return

        try:
            # Para o SDK client, precisamos descobrir agents disponíveis
            # Por enquanto, mantemos None e inicializamos conforme necessário
            self.sdk_client = None
            logger.info("SDK client initialization prepared")
        except Exception as e:
            logger.error(f"Failed to initialize SDK client: {e}")

    def _choose_implementation(
        self, preferred: Optional[A2AImplementation] = None
    ) -> A2AImplementation:
        """Escolhe a melhor implementação baseado na preferência e disponibilidade."""
        if preferred and preferred in self.available_implementations:
            return preferred

        if self.config.implementation != A2AImplementation.AUTO:
            if self.config.implementation in self.available_implementations:
                return self.config.implementation
            else:
                logger.warning(
                    f"Requested implementation {self.config.implementation.value} not available, "
                    f"falling back to auto-selection"
                )

        # Auto-seleção: prefere SDK se disponível, senão custom
        if A2AImplementation.SDK in self.available_implementations:
            return A2AImplementation.SDK
        elif A2AImplementation.CUSTOM in self.available_implementations:
            return A2AImplementation.CUSTOM
        else:
            raise ValueError("No A2A implementations available")

    async def get_agent_card(
        self,
        agent_id: Union[str, UUID],
        implementation: Optional[A2AImplementation] = None,
    ) -> A2AResponse:
        """
        Obtém agent card usando a implementação especificada ou a melhor disponível.
        """
        agent_id_str = str(agent_id)

        # Verifica cache
        cache_key = f"{agent_id_str}_{implementation}"
        if cache_key in self._agent_cards_cache:
            logger.debug(f"Returning cached agent card for {agent_id_str}")
            return self._agent_cards_cache[cache_key]

        chosen_impl = self._choose_implementation(implementation)

        try:
            if chosen_impl == A2AImplementation.SDK:
                response = await self._get_agent_card_sdk(agent_id_str)
            else:
                response = await self._get_agent_card_custom(agent_id_str)

            response.implementation_used = chosen_impl

            # Cache successful responses
            if response.success:
                self._agent_cards_cache[cache_key] = response

            return response

        except Exception as e:
            logger.error(f"Error getting agent card with {chosen_impl.value}: {e}")
            return A2AResponse(
                success=False,
                error=f"Failed to get agent card: {str(e)}",
                implementation_used=chosen_impl,
            )

    async def _get_agent_card_custom(self, agent_id: str) -> A2AResponse:
        """Obtém agent card usando implementação custom."""
        url = f"{self.config.base_url}/api/v1/a2a/{agent_id}/.well-known/agent.json"

        response = await self.httpx_client.get(url)
        response.raise_for_status()

        data = response.json()
        return A2AResponse(success=True, data=data, raw_response=response)

    async def _get_agent_card_sdk(self, agent_id: str) -> A2AResponse:
        """Obtém agent card usando implementação SDK."""
        url = f"{self.config.base_url}/api/v1/a2a-sdk/{agent_id}/.well-known/agent.json"

        response = await self.httpx_client.get(url)
        response.raise_for_status()

        data = response.json()
        return A2AResponse(success=True, data=data, raw_response=response)

    async def send_message(
        self,
        agent_id: Union[str, UUID],
        message: str,
        session_id: Optional[str] = None,
        implementation: Optional[A2AImplementation] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> A2AResponse:
        """
        Envia mensagem para agent usando a implementação especificada.
        """
        agent_id_str = str(agent_id)
        session_id = session_id or str(uuid4())

        chosen_impl = self._choose_implementation(implementation)

        try:
            if chosen_impl == A2AImplementation.SDK:
                response = await self._send_message_sdk(
                    agent_id_str, message, session_id, metadata
                )
            else:
                response = await self._send_message_custom(
                    agent_id_str, message, session_id, metadata
                )

            response.implementation_used = chosen_impl
            return response

        except Exception as e:
            logger.error(f"Error sending message with {chosen_impl.value}: {e}")
            return A2AResponse(
                success=False,
                error=f"Failed to send message: {str(e)}",
                implementation_used=chosen_impl,
            )

    async def _send_message_custom(
        self,
        agent_id: str,
        message: str,
        session_id: str,
        metadata: Optional[Dict[str, Any]],
    ) -> A2AResponse:
        """Envia mensagem usando implementação custom."""
        url = f"{self.config.base_url}/api/v1/a2a/{agent_id}"

        # Cria mensagem no formato custom
        custom_message = CustomMessage(
            role="user", parts=[{"type": "text", "text": message}], metadata=metadata
        )

        # Cria request usando método correto da especificação A2A
        request_data = {
            "jsonrpc": "2.0",
            "id": str(uuid4()),
            "method": "tasks/send",  # Método correto da especificação A2A
            "params": {
                "id": str(uuid4()),
                "sessionId": session_id,
                "message": (
                    custom_message.model_dump()
                    if hasattr(custom_message, "model_dump")
                    else custom_message.dict()
                ),
            },
        }

        response = await self.httpx_client.post(url, json=request_data)
        response.raise_for_status()

        data = response.json()
        return A2AResponse(success=True, data=data, raw_response=response)

    async def _send_message_sdk(
        self,
        agent_id: str,
        message: str,
        session_id: str,
        metadata: Optional[Dict[str, Any]],
    ) -> A2AResponse:
        """Envia mensagem usando implementação SDK - usa Message API conforme especificação."""
        if not SDK_AVAILABLE:
            raise ValueError("SDK not available")

        # Para implementação SDK, usamos o endpoint SDK
        url = f"{self.config.base_url}/api/v1/a2a-sdk/{agent_id}"

        # Message API conforme especificação oficial - apenas message nos params
        message_id = str(uuid4())

        # Formato exato da especificação oficial
        request_data = {
            "jsonrpc": "2.0",
            "id": str(uuid4()),
            "method": "message/send",
            "params": {
                "message": {
                    "role": "user",
                    "parts": [
                        {
                            "type": "text",  # Especificação usa "type" não "kind"
                            "text": message,
                        }
                    ],
                    "messageId": message_id,  # Obrigatório conforme especificação
                }
            },
        }

        response = await self.httpx_client.post(url, json=request_data)
        response.raise_for_status()

        data = response.json()
        return A2AResponse(success=True, data=data, raw_response=response)

    async def send_message_streaming(
        self,
        agent_id: Union[str, UUID],
        message: str,
        session_id: Optional[str] = None,
        implementation: Optional[A2AImplementation] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> AsyncIterator[A2AResponse]:
        """
        Envia mensagem com streaming usando a implementação especificada.
        """
        agent_id_str = str(agent_id)
        session_id = session_id or str(uuid4())

        chosen_impl = self._choose_implementation(implementation)

        try:
            if chosen_impl == A2AImplementation.SDK:
                async for response in self._send_message_streaming_sdk(
                    agent_id_str, message, session_id, metadata
                ):
                    response.implementation_used = chosen_impl
                    yield response
            else:
                async for response in self._send_message_streaming_custom(
                    agent_id_str, message, session_id, metadata
                ):
                    response.implementation_used = chosen_impl
                    yield response

        except Exception as e:
            logger.error(f"Error in streaming with {chosen_impl.value}: {e}")
            yield A2AResponse(
                success=False,
                error=f"Failed to stream message: {str(e)}",
                implementation_used=chosen_impl,
            )

    async def _send_message_streaming_custom(
        self,
        agent_id: str,
        message: str,
        session_id: str,
        metadata: Optional[Dict[str, Any]],
    ) -> AsyncIterator[A2AResponse]:
        """Envia mensagem com streaming usando implementação custom - usa Task API."""
        url = f"{self.config.base_url}/api/v1/a2a/{agent_id}/subscribe"

        # Cria mensagem no formato custom
        custom_message = CustomMessage(
            role="user", parts=[{"type": "text", "text": message}], metadata=metadata
        )

        # Nossa implementação custom usa Task API (tasks/subscribe)
        request_data = {
            "jsonrpc": "2.0",
            "id": str(uuid4()),
            "method": "tasks/subscribe",  # Task API para streaming custom
            "params": {
                "id": str(uuid4()),
                "sessionId": session_id,
                "message": (
                    custom_message.model_dump()
                    if hasattr(custom_message, "model_dump")
                    else custom_message.dict()
                ),
            },
        }

        async with self.httpx_client.stream(
            "POST", url, json=request_data, headers={"Accept": "text/event-stream"}
        ) as response:
            response.raise_for_status()

            async for line in response.aiter_lines():
                if line.startswith("data: "):
                    try:
                        data = json.loads(line[6:])  # Remove "data: "
                        yield A2AResponse(success=True, data=data, raw_response=line)
                    except json.JSONDecodeError:
                        logger.warning(f"Failed to parse SSE data: {line}")

    async def _send_message_streaming_sdk(
        self,
        agent_id: str,
        message: str,
        session_id: str,
        metadata: Optional[Dict[str, Any]],
    ) -> AsyncIterator[A2AResponse]:
        """Envia mensagem com streaming usando implementação SDK - usa Message API conforme especificação."""
        if not SDK_AVAILABLE:
            raise ValueError("SDK not available")

        url = f"{self.config.base_url}/api/v1/a2a-sdk/{agent_id}"

        # Message API conforme especificação oficial - apenas message nos params
        message_id = str(uuid4())

        # Formato exato da especificação oficial para streaming
        request_data = {
            "jsonrpc": "2.0",
            "id": str(uuid4()),
            "method": "message/stream",
            "params": {
                "message": {
                    "role": "user",
                    "parts": [
                        {
                            "type": "text",  # Especificação usa "type" não "kind"
                            "text": message,
                        }
                    ],
                    "messageId": message_id,  # Obrigatório conforme especificação
                }
            },
        }

        async with self.httpx_client.stream(
            "POST", url, json=request_data, headers={"Accept": "text/event-stream"}
        ) as response:
            response.raise_for_status()

            async for line in response.aiter_lines():
                if line.startswith("data: "):
                    try:
                        data = json.loads(line[6:])  # Remove "data: "
                        yield A2AResponse(success=True, data=data, raw_response=line)
                    except json.JSONDecodeError:
                        logger.warning(f"Failed to parse SSE data: {line}")

    async def compare_implementations(
        self, agent_id: Union[str, UUID]
    ) -> Dict[str, Any]:
        """
        Compara as duas implementações para um agent específico.
        """
        agent_id_str = str(agent_id)
        comparison = {
            "agent_id": agent_id_str,
            "available_implementations": [
                impl.value for impl in self.available_implementations
            ],
            "custom_card": None,
            "sdk_card": None,
            "differences": [],
        }

        # Obtém cards de ambas as implementações
        if A2AImplementation.CUSTOM in self.available_implementations:
            try:
                custom_response = await self._get_agent_card_custom(agent_id_str)
                if custom_response.success:
                    comparison["custom_card"] = custom_response.data
            except Exception as e:
                comparison["custom_error"] = str(e)

        if A2AImplementation.SDK in self.available_implementations:
            try:
                sdk_response = await self._get_agent_card_sdk(agent_id_str)
                if sdk_response.success:
                    comparison["sdk_card"] = sdk_response.data
            except Exception as e:
                comparison["sdk_error"] = str(e)

        # Compara se ambas estão disponíveis
        if comparison["custom_card"] and comparison["sdk_card"]:
            custom = comparison["custom_card"]
            sdk = comparison["sdk_card"]

            # Lista de campos para comparar
            fields_to_compare = ["name", "description", "version", "url"]

            for field in fields_to_compare:
                if custom.get(field) != sdk.get(field):
                    comparison["differences"].append(
                        {
                            "field": field,
                            "custom_value": custom.get(field),
                            "sdk_value": sdk.get(field),
                        }
                    )

        return comparison

    async def health_check(self) -> Dict[str, Any]:
        """
        Verifica saúde de todas as implementações disponíveis.
        """
        health = {
            "client_initialized": True,
            "available_implementations": [
                impl.value for impl in self.available_implementations
            ],
            "implementations_health": {},
        }

        # Testa custom implementation
        try:
            custom_health_url = f"{self.config.base_url}/api/v1/a2a/health"
            response = await self.httpx_client.get(custom_health_url)
            health["implementations_health"]["custom"] = {
                "available": response.status_code == 200,
                "status": response.status_code,
                "response": response.json() if response.status_code == 200 else None,
            }
        except Exception as e:
            health["implementations_health"]["custom"] = {
                "available": False,
                "error": str(e),
            }

        # Testa SDK implementation
        try:
            sdk_health_url = f"{self.config.base_url}/api/v1/a2a-sdk/health"
            response = await self.httpx_client.get(sdk_health_url)
            health["implementations_health"]["sdk"] = {
                "available": response.status_code == 200,
                "status": response.status_code,
                "response": response.json() if response.status_code == 200 else None,
            }
        except Exception as e:
            health["implementations_health"]["sdk"] = {
                "available": False,
                "error": str(e),
            }

        return health

    async def _detect_implementation(self) -> A2AImplementation:
        """Detecta automaticamente a implementação disponível."""
        logger.info("Auto-detecting A2A implementation...")

        # Se forçamos uma implementação específica, use-a
        if self.config.implementation != A2AImplementation.AUTO:
            logger.info(
                f"Using forced implementation: {self.config.implementation.value}"
            )
            return self.config.implementation

        # Se temos agent_id, verifica especificamente baseado na URL de health check
        agent_id = getattr(self, "_current_agent_id", None)

        implementations_to_try = []

        # Se o agent_id foi detectado como sendo de uma URL SDK específica, prefira SDK
        if (
            agent_id
            and hasattr(self, "_prefer_sdk_from_url")
            and self._prefer_sdk_from_url
        ):
            implementations_to_try = [A2AImplementation.SDK, A2AImplementation.CUSTOM]
        else:
            implementations_to_try = [A2AImplementation.CUSTOM, A2AImplementation.SDK]

        for impl in implementations_to_try:
            logger.info(f"Testing {impl.value} implementation...")

            if impl == A2AImplementation.SDK:
                if not SDK_AVAILABLE:
                    logger.info("SDK not available, skipping")
                    continue

                health_url = f"{self.config.base_url}/api/v1/a2a-sdk/health"
            else:
                health_url = f"{self.config.base_url}/api/v1/a2a/health"

            try:
                response = await self.httpx_client.get(health_url, timeout=5.0)
                if response.status_code == 200:
                    logger.info(f"✓ {impl.value} implementation is available")
                    return impl
                else:
                    logger.info(
                        f"✗ {impl.value} implementation returned {response.status_code}"
                    )
            except Exception as e:
                logger.info(f"✗ {impl.value} implementation failed: {str(e)}")

        # Fallback para custom se nada funcionar
        logger.warning("No implementation detected, falling back to CUSTOM")
        return A2AImplementation.CUSTOM


# Função utilitária para criar cliente facilmente
async def create_enhanced_a2a_client(
    base_url: str,
    api_key: str,
    implementation: A2AImplementation = A2AImplementation.AUTO,
    **kwargs,
) -> EnhancedA2AClient:
    """
    Função utilitária para criar e inicializar cliente A2A melhorado.
    """
    config = A2AClientConfig(
        base_url=base_url, api_key=api_key, implementation=implementation, **kwargs
    )

    client = EnhancedA2AClient(config)
    await client.initialize()
    return client


# Exemplo de uso
async def example_usage():
    """Exemplo de como usar o cliente melhorado."""
    config = A2AClientConfig(
        base_url="http://localhost:8000",
        api_key="your-api-key",
        implementation=A2AImplementation.AUTO,
    )

    async with EnhancedA2AClient(config) as client:
        # Health check
        health = await client.health_check()
        print("Health:", health)

        # Get agent card
        agent_id = "some-agent-id"
        card_response = await client.get_agent_card(agent_id)
        if card_response.success:
            print(
                f"Agent card obtained using {card_response.implementation_used.value}"
            )
            print("Card:", card_response.data)

        # Send message
        message_response = await client.send_message(
            agent_id=agent_id, message="Hello, how can you help me?"
        )
        if message_response.success:
            print(f"Message sent using {message_response.implementation_used.value}")
            print("Response:", message_response.data)

        # Send streaming message
        print("Streaming response:")
        async for chunk in client.send_message_streaming(
            agent_id=agent_id, message="Tell me a story"
        ):
            if chunk.success:
                print(f"Chunk ({chunk.implementation_used.value}):", chunk.data)

        # Compare implementations
        comparison = await client.compare_implementations(agent_id)
        print("Implementation comparison:", comparison)
