"""
Automatic OAuth redirect_uri derivation.

The OAuth callback route is FIXED per provider (``/<slug>/callback`` on the
frontend); only the host changes between environments (dev ``localhost:5173``,
prod ``app.example.com``). Instead of requiring a per-environment/per-tenant
``*_REDIRECT_URI`` config, we derive it from the ``Origin`` (or ``Referer``)
header of the browser request that reaches this service.

The browser calls the processor same-origin (Vite proxies ``/evoproc`` →
processor with ``changeOrigin: true``, which rewrites ``Host`` but leaves the
browser-set ``Origin`` header intact), so ``Origin`` is exactly the frontend
origin. Because both the authorization URL and the token exchange are built from
the same request, the two redirect_uri values match by construction.

If no ``Origin``/``Referer`` header is present (non-browser caller), the derived
value is ``None`` and the existing config-based value (if any) is used as-is.
"""

from typing import Optional
from urllib.parse import urlsplit

from fastapi import Request

# Maps the provider key (used internally / in config keys) to the exact URL slug
# of its frontend callback route. Keep this BYTE-FOR-BYTE in sync with the
# frontend callback routes (``/<slug>/callback``) and with whatever is registered
# in each provider's OAuth app — a single-byte mismatch causes
# ``redirect_uri_mismatch`` at the provider. Note the Google providers use a
# hyphen ("google-calendar"), not the underscore of the provider key.
PROVIDER_CALLBACK_SLUGS = {
    "github": "github",
    "notion": "notion",
    "asana": "asana",
    "canva": "canva",
    "monday": "monday",
    "atlassian": "atlassian",
    "paypal": "paypal",
    "hubspot": "hubspot",
    "linear": "linear",
    "google_calendar": "google-calendar",
    "google_sheets": "google-sheets",
}


def _front_origin(request: Request) -> Optional[str]:
    """Return the frontend origin ("scheme://host[:port]") from the request.

    Prefers the ``Origin`` header (present on browser XHR/fetch); falls back to
    deriving the origin from ``Referer``. Returns ``None`` when neither is
    usable so the caller can fall back to configured values.
    """
    origin = request.headers.get("origin")
    if origin:
        origin = origin.strip()
        if origin and origin.lower() != "null":
            return origin.rstrip("/")

    referer = request.headers.get("referer")
    if referer:
        parts = urlsplit(referer.strip())
        if parts.scheme and parts.netloc:
            return f"{parts.scheme}://{parts.netloc}"

    return None


def derive_redirect_uri(request: Request, provider: str) -> Optional[str]:
    """Derive ``<front-origin>/<slug>/callback`` for ``provider``.

    Returns ``None`` if the provider is unknown or the request carries no usable
    front origin, so callers can keep any configured redirect_uri untouched.
    """
    slug = PROVIDER_CALLBACK_SLUGS.get(provider)
    if not slug:
        return None

    origin = _front_origin(request)
    if not origin:
        return None

    return f"{origin}/{slug}/callback"
