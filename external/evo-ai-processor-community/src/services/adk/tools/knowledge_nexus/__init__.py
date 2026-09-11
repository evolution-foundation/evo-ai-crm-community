"""Knowledge Nexus tools for the ADK.

Provides a native retrieval tool backed by the EvoNexus Knowledge API
(hybrid vector + BM25 + RRF search).
"""

from .search_tool import create_knowledge_nexus_search_tool

__all__ = ["create_knowledge_nexus_search_tool"]
