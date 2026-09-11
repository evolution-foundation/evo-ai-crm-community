import asyncio
from logging.config import fileConfig

from sqlalchemy import engine_from_config
from sqlalchemy import pool
from sqlalchemy.ext.asyncio import create_async_engine

from sqlalchemy.ext.asyncio import AsyncEngine

from alembic import context

from src.models.models import Base
from src.config.settings import settings

# this is the Alembic Config object, which provides
# access to the values within the .ini file in use.
config = context.config

# Sobrescreve a URL do banco de dados com a definida nas configurações
config.set_main_option("sqlalchemy.url", settings.POSTGRES_CONNECTION_STRING)

# Interpret the config file for Python logging.
# This line sets up loggers basically.
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# add your model's MetaData object here
# for 'autogenerate' support
# from myapp import mymodel
# target_metadata = mymodel.Base.metadata
target_metadata = [Base.metadata]

# other values from the config, defined by the needs of env.py,
# can be acquired:
# my_important_option = config.get_main_option("my_important_option")
# ... etc.

# Lista de tabelas a serem ignoradas na geração automática de migrações
exclude_tables = ["sessions", "events", "app_states", "user_states", "users"]


def include_object(object, name, type_, reflected, compare_to):
    """
    Função de filtro para excluir determinadas tabelas da geração automática de migrações
    """
    if type_ == "table" and name in exclude_tables:
        return False
    return True


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode.

    This configures the context with just a URL
    and not an Engine, though an Engine is acceptable
    here as well.  By skipping the Engine creation
    we don't even need a DBAPI to be available.

    Calls to context.execute() here emit the given string to the
    script output.

    """
    url = config.get_main_option("sqlalchemy.url")
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
        include_object=include_object,
    )

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode.

    In this scenario we need to create an Engine
    and associate a connection with the context.

    """
    connectable = context.config.attributes.get("connection", None)
    if connectable is None:
        # asyncpg rejects the libpq `sslmode` query param (it uses `ssl`); rewrite
        # ANY value. The old `=require`-only rewrite left `sslmode=disable` intact
        # (the Swarm overlay runs sslmode=disable), which crashed alembic at connect
        # and silently skipped every online migration.
        db_url = context.config.get_main_option("sqlalchemy.url")
        async_db_url = db_url.replace("postgresql://", "postgresql+asyncpg://", 1)
        async_db_url = async_db_url.replace("?sslmode=", "?ssl=").replace("&sslmode=", "&ssl=")
        connectable = create_async_engine(
            async_db_url,
            poolclass=pool.NullPool,
            future=True,
        )

    if isinstance(connectable, AsyncEngine):
        asyncio.run(run_async_migrations(connectable))
    else:
        do_run_migrations(connectable)


async def run_async_migrations(connectable):
    async with connectable.connect() as connection:
        await connection.run_sync(do_run_migrations)
    await connectable.dispose()


def do_run_migrations(connection):
    context.configure(
        connection=connection,
        target_metadata=target_metadata,
        compare_type=True,
        include_object=include_object,
    )
    with context.begin_transaction():
        context.run_migrations()


run_migrations_online()
