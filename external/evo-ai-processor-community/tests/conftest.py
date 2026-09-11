"""Environment bootstrap for the unit suite.

Several modules read configuration at import time — `src/utils/crypto.py` demands
ENCRYPTION_KEY, and `src/services/service_providers.py` builds a
DatabaseSessionService from POSTGRES_CONNECTION_STRING — so importing anything
that transitively reaches them (chat_routes, the middleware) blows up before a
single test runs. These are placeholders: SQLAlchemy resolves the URL lazily, so
nothing here opens a connection. Real values in the environment still win.
"""

import os

os.environ.setdefault("ENCRYPTION_KEY", "hAAcxHzMlM1BiZWpVQlZ4b0hTZ0dJbEZzWWVQb0k9PQ=")
os.environ.setdefault(
    "POSTGRES_CONNECTION_STRING", "postgresql://tests:tests@localhost:5432/tests"
)
os.environ.setdefault("JWT_SECRET_KEY", "test-secret")
