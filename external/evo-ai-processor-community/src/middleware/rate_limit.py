"""
┌──────────────────────────────────────────────────────────────────────────────┐
│ @author: Davidson Gomes                                                      │
│ @file: rate_limit.py                                                         │
│ Developed by: Danilo Leone                                                   │
│ Creation date: August 21, 2025                                               │
│ Contact: contato@evolution-api.com                                           │
├──────────────────────────────────────────────────────────────────────────────┤
│ @copyright © Evolution API 2024. All rights reserved.                        │
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
│ └──────────────────────────────────────────────────────────────────────────────┘
"""

import time
import threading
from typing import Dict
from dataclasses import dataclass

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.types import ASGIApp

from src.utils.logger import setup_logger

logger = setup_logger(__name__)


@dataclass
class TokenBucket:
    """Token bucket implementation for rate limiting"""
    capacity: int
    tokens: float
    rate: float
    last_update: float
    
    def __post_init__(self):
        self.last_update = time.time()
    
    def consume(self, tokens: int = 1) -> bool:
        """Consume tokens from the bucket"""
        now = time.time()
        
        # Add tokens based on time passed
        elapsed = now - self.last_update
        self.tokens = min(self.capacity, self.tokens + elapsed * self.rate)
        self.last_update = now
        
        # Check if we have enough tokens
        if self.tokens >= tokens:
            self.tokens -= tokens
            return True
        return False
    
    def is_empty(self) -> bool:
        """Check if bucket has been unused (full tokens)"""
        now = time.time()
        elapsed = now - self.last_update
        potential_tokens = min(self.capacity, self.tokens + elapsed * self.rate)
        return potential_tokens >= self.capacity and elapsed > 300  # 5 minutes


class RateLimiter:
    """Rate limiter with token bucket algorithm"""
    
    def __init__(self, requests_per_second: float, burst: int, cleanup_interval: int = 300):
        self.rate = requests_per_second
        self.burst = burst
        self.cleanup_interval = cleanup_interval
        self.buckets: Dict[str, TokenBucket] = {}
        self._lock = threading.RLock()
        self._start_cleanup_task()
    
    def _start_cleanup_task(self):
        """Start background cleanup task"""
        def cleanup_old_buckets():
            while True:
                try:
                    time.sleep(self.cleanup_interval)
                    self._cleanup_old_buckets()
                except Exception as e:
                    logger.error(f"Error in rate limiter cleanup: {e}")
        
        cleanup_thread = threading.Thread(target=cleanup_old_buckets, daemon=True)
        cleanup_thread.start()
        logger.info(f"Rate limiter cleanup started with interval {self.cleanup_interval}s")
    
    def _cleanup_old_buckets(self):
        """Remove unused buckets to prevent memory leaks"""
        with self._lock:
            to_remove = []
            for client_id, bucket in self.buckets.items():
                if bucket.is_empty():
                    to_remove.append(client_id)
            
            for client_id in to_remove:
                del self.buckets[client_id]
            
            if to_remove:
                logger.debug(f"Cleaned up {len(to_remove)} unused rate limiter buckets")
    
    def get_bucket(self, client_id: str) -> TokenBucket:
        """Get or create a token bucket for a client"""
        with self._lock:
            if client_id not in self.buckets:
                self.buckets[client_id] = TokenBucket(
                    capacity=self.burst,
                    tokens=float(self.burst),
                    rate=self.rate,
                    last_update=time.time()
                )
            return self.buckets[client_id]
    
    def allow(self, client_id: str) -> bool:
        """Check if request is allowed for client"""
        bucket = self.get_bucket(client_id)
        return bucket.consume(1)


class GlobalRateLimitMiddleware(BaseHTTPMiddleware):
    """Global rate limiting middleware"""
    
    def __init__(self, app: ASGIApp, requests_per_second: float, burst: int):
        super().__init__(app)
        self.limiter = TokenBucket(
            capacity=burst,
            tokens=float(burst),
            rate=requests_per_second,
            last_update=time.time()
        )
        logger.info(f"Global rate limiter initialized: {requests_per_second} RPS, burst {burst}")
    
    async def dispatch(self, request: Request, call_next):
        # Skip OPTIONS (CORS preflight) and health endpoints
        if request.method == "OPTIONS" or request.url.path in ["/health", "/ready", "/healthz"]:
            return await call_next(request)

        if not self.limiter.consume(1):
            return JSONResponse(
                status_code=429,
                content={
                    "error": "Global rate limit exceeded",
                    "message": "Server is experiencing high load, please try again later",
                    "retry_after": "30 seconds"
                }
            )

        return await call_next(request)


class RateLimitMiddleware(BaseHTTPMiddleware):
    """Per-client rate limiting middleware"""
    
    def __init__(self, app: ASGIApp, requests_per_second: float, burst: int, cleanup_interval: int = 300):
        super().__init__(app)
        self.limiter = RateLimiter(requests_per_second, burst, cleanup_interval)
        logger.info(f"Per-client rate limiter initialized: {requests_per_second} RPS, burst {burst}")
    
    def _get_client_id(self, request: Request) -> str:
        """Get client identifier for rate limiting"""
        # Try to get user/account context from request
        client_ip = request.client.host if request.client else "unknown"
        
        # Check if we have user information in request state
        if hasattr(request.state, "current_user") and request.state.current_user:
            user_id = request.state.current_user.get("user_id")
            if user_id:
                return f"user_{user_id}"
        
        # Check authorization header for JWT
        auth_header = request.headers.get("authorization", "")
        if auth_header.startswith("Bearer "):
            token_hash = hash(auth_header)
            return f"token_{abs(token_hash)}"
        
        # Fallback to IP address
        return f"ip_{client_ip}"
    
    async def dispatch(self, request: Request, call_next):
        # Skip OPTIONS (CORS preflight) and health endpoints
        if request.method == "OPTIONS" or request.url.path in ["/health", "/ready", "/healthz"]:
            return await call_next(request)

        client_id = self._get_client_id(request)
        
        if not self.limiter.allow(client_id):
            return JSONResponse(
                status_code=429,
                content={
                    "error": "Rate limit exceeded",
                    "message": "Too many requests, please try again later",
                    "retry_after": "1 minute",
                    "client_id": client_id.split("_")[0]  # Only return type, not full ID
                }
            )
        
        return await call_next(request)
