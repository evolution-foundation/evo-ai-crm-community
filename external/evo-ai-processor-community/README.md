<p align="center">
  <a href="https://evolutionfoundation.com.br">
    <img src="./public/hover-evolution.png" alt="Evolution Foundation" />
  </a>
</p>

<h1 align="center">Evo CRM Agent Processor</h1>

<p align="center">
  Agent execution, session orchestration, and knowledge search service for the Evo CRM Community.
</p>

<p align="center">
  <a href="https://github.com/evolution-foundation/evo-ai-processor-community/releases/latest"><img src="https://img.shields.io/github/v/release/evolution-foundation/evo-ai-processor-community?include_prereleases&label=version&color=00ffa7" alt="Latest version" /></a>
  <a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License: Apache 2.0" /></a>
  <a href="https://docs.evolutionfoundation.com.br"><img src="https://img.shields.io/badge/Docs-evolutionfoundation.com.br-00ffa7" alt="Documentation" /></a>
  <a href="https://evolutionfoundation.com.br/community"><img src="https://img.shields.io/badge/Community-Join%20us-white" alt="Community" /></a>
</p>

<p align="center">
  <a href="https://evolutionfoundation.com.br">Website</a> &middot;
  <a href="https://docs.evolutionfoundation.com.br">Documentation</a> &middot;
  <a href="https://evolutionfoundation.com.br/community">Community</a> &middot;
  <a href="mailto:suporte@evofoundation.com.br">Support</a>
</p>

---

## About

**Evo CRM Agent Processor** is the AI execution core of the Evo CRM Community. It orchestrates intelligent workflows between multiple agents, manages sessions and artifacts, executes Google ADK agents, and integrates with vector databases for semantic knowledge search.

Built with FastAPI, it provides:

- Workflow orchestration between agents using LangGraph
- Execution of Google ADK agents and integration with Google GenAI
- Session, event, and artifact processing
- Knowledge search and storage in vector databases (Pinecone, Qdrant, OpenSearch)
- JWT authentication for protected endpoints
- Redis caching for performance
- OpenAI and provider-neutral integrations for embeddings
- RESTful API with FastAPI
- Observability via OpenTelemetry

## Part of the Evo CRM Community

Evo CRM Agent Processor is part of the [Evo CRM Community](https://github.com/evolution-foundation/evo-crm-community) ecosystem maintained by Evolution Foundation. To use the full stack, clone the umbrella repository with submodules:

```bash
git clone --recurse-submodules git@github.com:evolution-foundation/evo-crm-community.git
```

The Community Edition is **single-tenant** by design — one account, no multi-tenancy overhead, no super-admin, no billing or plans. All limits are removed and features are unlocked by default.

---

## Tech Stack

| Component | Technology |
|---|---|
| Web framework | FastAPI |
| ORM | SQLAlchemy |
| Database | PostgreSQL 13+ |
| Cache | Redis 6+ |
| ASGI server | Uvicorn |
| Authentication | JWT (python-jose, pyjwt) |
| Vector databases | Pinecone, Qdrant, OpenSearch |
| Agents | Google ADK, LangGraph |
| Artifact storage | MinIO |
| Observability | OpenTelemetry |
| Migrations | Alembic |

---

## Quick Start

### Prerequisites

- **Python** 3.10+
- **PostgreSQL** 13.0+
- **Redis** 6.0+
- **uv** package manager: `curl -LsSf https://astral.sh/uv/install.sh | sh`
- **Make**

### Installation

```bash
git clone git@github.com:evolution-foundation/evo-ai-processor-community.git
cd evo-ai-processor-community

# Create virtual environment and install dependencies
make venv
source venv/bin/activate  # Linux/Mac
make install-dev

# Configure environment
cp .env.example .env
# Edit .env with your settings
```

### Running

```bash
make run         # Development with hot reload
make run-prod    # Production
```

The API will be available at `http://localhost:8000`.

### Docker

```bash
make docker-build
make docker-up
make docker-seed
```

---

## Development

```bash
# Code quality
make lint        # Verify with flake8
make format      # Format with black

# Cache management
make clear-python-cache    # Remove .pyc and __pycache__
make clear-uv-cache        # Clean UV cache
make clear-all-cache       # Comprehensive cleanup

# Environment
make reset-venv            # Recreate virtual environment
make refresh-env           # Reset and reinstall dependencies
```

---

## Architecture

The processor sits between the bot runtime and the agent execution layer:

```
Evo Bot Runtime
      ↓
Evo CRM Agent Processor  ← (you are here)
      ↓
Google ADK / LangGraph + Vector DBs (Pinecone/Qdrant/OpenSearch)
      ↓
Evo CRM Backend (persistence)
```

Key responsibilities:
- **Session management**: per-conversation agent state
- **Artifact storage**: stores intermediate results in MinIO
- **Vector search**: semantic retrieval over knowledge bases
- **Workflow orchestration**: LangGraph-based multi-agent flows
- **Event processing**: emits events for downstream services

---

## Documentation

| Resource | Link |
|---|---|
| Website | [evolutionfoundation.com.br](https://evolutionfoundation.com.br) |
| Documentation | [docs.evolutionfoundation.com.br](https://docs.evolutionfoundation.com.br) |
| Community | [evolutionfoundation.com.br/community](https://evolutionfoundation.com.br/community) |
| Changelog | [CHANGELOG.md](./CHANGELOG.md) |
| Contributing | [CONTRIBUTING.md](./CONTRIBUTING.md) |
| Security | [SECURITY.md](./SECURITY.md) |

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines on how to submit issues, propose features, and open pull requests.

Join our [community](https://evolutionfoundation.com.br/community) to discuss ideas and collaborate.

---

## Security

For security issues, **do not open a public issue**. Email **suporte@evofoundation.com.br** or use GitHub's private vulnerability reporting. See [SECURITY.md](./SECURITY.md) for details.

---

## Acknowledgments

This service builds on excellent open-source software:
- [FastAPI](https://fastapi.tiangolo.com/) — web framework
- [LangGraph](https://github.com/langchain-ai/langgraph) — agent workflow orchestration
- [Google ADK](https://github.com/google/adk-python) — agent execution
- [Pinecone](https://www.pinecone.io/), [Qdrant](https://qdrant.tech/), [OpenSearch](https://opensearch.org/) — vector databases
- [Alembic](https://alembic.sqlalchemy.org/) — database migrations

---

## License

Evo CRM Agent Processor is licensed under the Apache License 2.0. See [LICENSE](./LICENSE) for details.

## Trademarks

"Evolution Foundation", "Evolution" and "Evo CRM Agent Processor" are trademarks of Evolution Foundation. See [TRADEMARKS.md](./TRADEMARKS.md) for the brand assets policy.

Third-party attributions are documented in [NOTICE](./NOTICE).

---

<p align="center">
  Made by <a href="https://evolutionfoundation.com.br">Evolution Foundation</a> · © 2026
</p>
