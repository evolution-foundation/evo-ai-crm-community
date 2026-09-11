.PHONY: setup dev run install db-setup db-migrate db-seed db-reset migrate-up migrate-down migrate-create alembic-revision alembic-upgrade alembic-downgrade alembic-migrate alembic-reset seed-mcp-servers seed-all docker-build docker-up docker-down docker-logs lint format install-dev venv clear-cache clear-python-cache clear-uv-cache clear-all-cache reset-venv refresh-env help

# =============================================================================
# PADRÃO PADRONIZADO - COMANDOS PRINCIPAIS
# =============================================================================

# Setup completo do projeto (install + db-setup)
setup: install db-setup
	@echo "✅ Setup completo concluído!"

# Instalar dependências
install:
	@echo "📦 Instalando dependências..."
	uv venv || true
	uv pip install -e ".[dev]"
	@echo "✅ Dependências instaladas!"

# Rodar em modo desenvolvimento
dev:
	@echo "🔧 Iniciando EvoAI Processor em modo desenvolvimento..."
	uvicorn src.main:app --host 0.0.0.0 --port 8000 --reload --env-file .env

# Rodar em modo produção
run:
	@echo "🚀 Iniciando EvoAI Processor em modo produção..."
	uvicorn src.main:app --host 0.0.0.0 --port 8000 --workers 4

# Setup do banco de dados (create + migrate)
db-setup:
	@echo "🗄️  Configurando banco de dados..."
	@echo "⚠️  Certifique-se de que o PostgreSQL está rodando e configurado no .env"
	alembic upgrade head
	@echo "✅ Banco de dados configurado!"

# Rodar migrações pendentes
db-migrate: migrate-up

# Rodar seeds
db-seed: seed-all

# Resetar banco completo (drop + create + migrate)
db-reset:
	@echo "🔄 Resetando banco de dados..."
	@echo "⚠️  ATENÇÃO: Isso irá apagar todos os dados!"
	@read -p "Tem certeza? [y/N]: " confirm && [ "$$confirm" = "y" ] || exit 1
	alembic downgrade base || true
	alembic upgrade head
	@echo "✅ Banco de dados resetado!"

# =============================================================================
# COMANDOS DE MIGRAÇÃO (PADRÃO PADRONIZADO)
# =============================================================================

# Rodar migrações pendentes
migrate-up:
	@echo "🚀 Rodando migrações pendentes..."
	alembic upgrade head
	@echo "✅ Migrações aplicadas!"

# Reverter última migração
migrate-down:
	@echo "⬇️  Revertendo última migração..."
	alembic downgrade -1
	@echo "✅ Migração revertida!"

# Criar nova migração (uso: make migrate-create NAME=nome_da_migracao)
migrate-create:
	@if [ -z "$(NAME)" ]; then \
		echo "❌ NAME é obrigatório. Use: make migrate-create NAME=nome_da_migracao"; \
		exit 1; \
	fi
	@echo "📝 Criando nova migração: $(NAME)..."
	alembic revision --autogenerate -m "$(NAME)"
	@echo "✅ Migração criada!"

# =============================================================================
# COMANDOS ALEMBIC (COMPATIBILIDADE)
# =============================================================================

init:
	alembic init alembics

# make alembic-revision message="migration description"
alembic-revision:
	alembic revision --autogenerate -m "$(message)"

# Command to update database to latest version (execute existing migrations)
alembic-upgrade: migrate-up

# Command to downgrade one version
alembic-downgrade: migrate-down

# Command to create a new migration and apply it
alembic-migrate: ## Criar e aplicar migração (compatibilidade)
	@if [ -z "$(message)" ]; then \
		echo "❌ message is required. Use: make alembic-migrate message=\"descrição\""; \
		exit 1; \
	fi
	alembic revision --autogenerate -m "$(message)" && alembic upgrade head

# Command to reset the database
alembic-reset: db-reset

# Command to clean cache in all project folders
clear-cache:
	rm -rf ~/.cache/uv/environments-v2/* && find . -type d -name "__pycache__" -exec rm -r {} +

# Command to clean all Python cache files
clear-python-cache:
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.pyc" -delete 2>/dev/null || true
	find . -name "*.pyo" -delete 2>/dev/null || true
	find . -name "*.pyd" -delete 2>/dev/null || true
	find . -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true

# Command to clean UV cache
clear-uv-cache:
	uv cache clean

# Command to clean all caches (comprehensive)
clear-all-cache:
	@echo "🧹 Cleaning Python cache files..."
	find . -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.pyc" -delete 2>/dev/null || true
	find . -name "*.pyo" -delete 2>/dev/null || true
	find . -name "*.pyd" -delete 2>/dev/null || true
	find . -name ".pytest_cache" -exec rm -rf {} + 2>/dev/null || true
	find . -name "*.egg-info" -exec rm -rf {} + 2>/dev/null || true
	@echo "🧹 Cleaning UV cache..."
	uv cache clean 2>/dev/null || true
	rm -rf ~/.cache/uv/environments-v2/* 2>/dev/null || true
	@echo "🧹 Cleaning system cache..."
	sudo purge 2>/dev/null || true
	@echo "✅ All caches cleared!"

# Command to reset virtual environment
reset-venv:
	@echo "🔄 Resetting virtual environment..."
	rm -rf .venv 2>/dev/null || true
	uv venv
	@echo "✅ Virtual environment reset!"

# Command to refresh environment (reset venv + reinstall)
refresh-env:
	@echo "🔄 Refreshing development environment..."
	rm -rf .venv 2>/dev/null || true
	uv venv
	uv pip install -e ".[dev]"
	@echo "✅ Environment refreshed!"

# Command to create a new migration and apply it
alembic-migrate: ## Criar e aplicar migração (compatibilidade)
	@if [ -z "$(message)" ]; then \
		echo "❌ message is required. Use: make alembic-migrate message=\"descrição\""; \
		exit 1; \
	fi
	alembic revision --autogenerate -m "$(message)" && alembic upgrade head

# Command to reset the database
alembic-reset: db-reset ## Resetar banco (compatibilidade)
	
# Commands to run seeders

seed-mcp-servers:
	python -m scripts.seeders.mcp_server_seeder

seed-all:
	python -m scripts.run_seeders

# Docker commands
docker-build:
	docker-compose build

docker-up:
	docker-compose up -d

docker-down:
	docker-compose down

docker-logs:
	docker-compose logs -f

docker-seed:
	docker-compose exec api python -m scripts.run_seeders

# Testing, linting and formatting commands
lint:
	flake8 src/ tests/

format:
	black src/ tests/

# Virtual environment and installation commands
venv:
	python -m venv venv

install:
	pip install -e .

install-dev:
	pip install -e ".[dev]"

# =============================================================================
# HELP
# =============================================================================

help: ## Mostrar ajuda com todos os comandos
	@echo "EvoAI Processor - Makefile Commands"
	@echo ""
	@echo "🚀 Quick Start (PADRÃO PADRONIZADO):"
	@echo "  make setup          - Setup completo (install + db-setup)"
	@echo "  make dev            - Rodar em modo desenvolvimento"
	@echo "  make run            - Rodar em modo produção"
	@echo ""
	@echo "📦 Setup & Installation:"
	@echo "  make install        - Instalar dependências"
	@echo "  make setup          - Setup completo (install + db-setup)"
	@echo ""
	@echo "🗄️ Database Management (PADRÃO PADRONIZADO):"
	@echo "  make db-setup       - Setup inicial do banco (create + migrate)"
	@echo "  make db-migrate     - Rodar migrações pendentes"
	@echo "  make db-seed        - Rodar seeds"
	@echo "  make db-reset       - Resetar banco completo"
	@echo ""
	@echo "🔄 Migrations (PADRÃO PADRONIZADO):"
	@echo "  make migrate-up     - Rodar migrações pendentes"
	@echo "  make migrate-down   - Reverter última migração"
	@echo "  make migrate-create NAME=nome - Criar nova migração"
	@echo ""
	@echo "🔄 Alembic Commands (Compatibilidade):"
	@echo "  make alembic-upgrade - Rodar migrações (alias para migrate-up)"
	@echo "  make alembic-downgrade - Reverter migração (alias para migrate-down)"
	@echo "  make alembic-revision message=\"desc\" - Criar migração"
	@echo "  make alembic-migrate message=\"desc\" - Criar e aplicar migração"
	@echo "  make alembic-reset - Resetar banco (alias para db-reset)"
	@echo ""
	@echo "🌱 Seeds:"
	@echo "  make db-seed        - Rodar seeds (padrão padronizado)"
	@echo "  make seed-mcp-servers - Popular servidores MCP"
	@echo "  make seed-all         - Rodar todos os seeders"
	@echo ""
	@echo "🧹 Cleanup:"
	@echo "  make clean          - Limpar cache e arquivos temporários"
	@echo "  make clear-cache    - Limpar cache Python e UV"
	@echo "  make clear-all-cache - Limpar todos os caches"
	@echo ""
	@echo "🐳 Docker:"
	@echo "  make docker-build   - Build da imagem"
	@echo "  make docker-up      - Subir containers"
	@echo "  make docker-down    - Parar containers"
	@echo "  make docker-logs    - Ver logs"