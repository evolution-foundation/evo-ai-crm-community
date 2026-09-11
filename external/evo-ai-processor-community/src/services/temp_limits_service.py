"""
Simple Limits Service
Basic limits checking using existing database tables
"""

from typing import Dict, Tuple, List
from datetime import datetime, timedelta
from sqlalchemy.orm import Session
from sqlalchemy import func
from src.models.models import Agent, Session as ADKSession
from src.utils.logger import setup_logger

COMMUNITY_MEMORY_RETENTION_DAYS = 30
COMMUNITY_MAX_SESSIONS_PER_MONTH = 10000
COMMUNITY_MAX_CONCURRENT_SESSIONS = 100

logger = setup_logger(__name__)


def get_memory_retention_days() -> int:
    """Get max days to retain memory."""
    return COMMUNITY_MEMORY_RETENTION_DAYS

# Functions to count various limits based on database queries
def count_user_agents(db: Session) -> int:
    """Count all agents."""
    try:
        return (
            db.query(func.count(Agent.id)).scalar()
            or 0
        )
    except Exception as e:
        logger.error(f"Error counting agents: {e}")
        return 0

# Count sessions created this month
def count_user_sessions_this_month(db: Session) -> int:
    """Count sessions created this month."""
    try:
        start_of_month = datetime.utcnow().replace(
            day=1, hour=0, minute=0, second=0, microsecond=0
        )

        return (
            db.query(func.count(ADKSession.id))
            .filter(
                ADKSession.create_time >= start_of_month
            )
            .scalar()
            or 0
        )
    except Exception as e:
        logger.error(f"Error counting monthly sessions: {e}")
        return 0

# Count active sessions (updated in last 10 minutes)
def count_user_active_sessions(db: Session) -> int:
    """Count active sessions (updated in last 10 minutes)."""
    try:
        cutoff_time = datetime.utcnow() - timedelta(minutes=10)

        return (
            db.query(func.count(ADKSession.id))
            .filter(
                ADKSession.update_time >= cutoff_time
            )
            .scalar()
            or 0
        )
    except Exception as e:
        logger.error(f"Error counting active sessions: {e}")
        return 0

# Check if there are old memory entries that should be cleaned up
def check_old_memory_entries(db: Session, retention_days: int) -> int:
    """Count memory entries older than retention limit."""
    try:
        cutoff_date = datetime.utcnow() - timedelta(days=retention_days)

        # Check memory entries in OpenSearch or similar
        # For now, we'll check session age as a proxy
        old_sessions = (
            db.query(func.count(ADKSession.id))
            .filter(
                ADKSession.update_time < cutoff_date
            )
            .scalar()
            or 0
        )

        return old_sessions
    except Exception as e:
        logger.error(f"Error checking old memory: {e}")
        return 0

# Check if another session can be created this month
def check_session_limit(db: Session) -> Tuple[bool, str]:
    """Check if another session can be created this month."""
    try:
        monthly_limit = COMMUNITY_MAX_SESSIONS_PER_MONTH
        concurrent_limit = COMMUNITY_MAX_CONCURRENT_SESSIONS

        # Check monthly limit
        current_monthly_count = count_user_sessions_this_month(db)
        if current_monthly_count >= monthly_limit:
            return (
                False,
                f"Monthly session limit of {monthly_limit} reached. Upgrade for unlimited sessions!",
            )

        # Check concurrent sessions limit
        current_active_count = count_user_active_sessions(db)
        if current_active_count >= concurrent_limit:
            return (
                False,
                f"Maximum {concurrent_limit} concurrent sessions reached. Please wait or upgrade!",
            )

        return True, ""
    except Exception as e:
        logger.error(f"Error checking session limits: {e}")
        return False, "Unable to verify session limits"

# Check if there are memory entries that should be cleaned up
def check_memory_retention(db: Session) -> Tuple[bool, str]:
    """Check if there are memory entries that should be cleaned up."""
    try:
        retention_days = COMMUNITY_MEMORY_RETENTION_DAYS
        old_entries = check_old_memory_entries(db, retention_days)

        if old_entries > 0:
            return (
                False,
                f"Plan retains memory for {retention_days} days. {old_entries} old entries found.",
            )

        return True, ""
    except Exception as e:
        logger.error(f"Error checking memory retention: {e}")
        return False, "Unable to verify memory retention limits"

# Build usage summary
def _build_usage_summary(
    session_limit: int = 1,
    concurrent_limit: int = 1,
    retention_days: int = 1,
    sessions_count: int = 1,
    active_count: int = 1,
    old_memory: int = 1
    ) -> dict:
        return {
            "usage": {
                "sessions_this_month": f"{sessions_count}/{session_limit}",
                "active_sessions": f"{active_count}/{concurrent_limit}",
                "memory_retention_days": f"{retention_days}",
                "old_memory_entries": old_memory,
            },
            "warnings": [
                f"You've used {round((sessions_count/session_limit)*100)}% of your monthly sessions"
                for sessions_count, session_limit in [(sessions_count, session_limit)]
                if sessions_count / session_limit >= 0.8
            ]
            + (
                [f"You have {old_memory} old memory entries that will be cleaned up"]
                if old_memory > 0
                else []
            ),
        }
# Get usage summary
def get_usage_summary(db: Session) -> dict:
    """Get simple usage summary. Community edition uses fixed defaults."""
    try:
        sessions_count = int(count_user_sessions_this_month(db))
        active_count = int(count_user_active_sessions(db))
        old_memory = int(check_old_memory_entries(db, COMMUNITY_MEMORY_RETENTION_DAYS))
        return _build_usage_summary(
            COMMUNITY_MAX_SESSIONS_PER_MONTH,
            COMMUNITY_MAX_CONCURRENT_SESSIONS,
            COMMUNITY_MEMORY_RETENTION_DAYS,
            sessions_count,
            active_count,
            old_memory,
        )
    except Exception as e:
        logger.error(f"Error getting usage summary: {e}")
        return {"error": "Unable to get usage data"}