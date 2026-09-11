"""

Revision ID: 26a14ac7025d
Revises: 
Create Date: 2025-08-21 09:23:27.584955

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '26a14ac7025d'
down_revision: Union[str, None] = None
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None

metadata = sa.MetaData()

execution_metrics = sa.Table(
    'evo_agent_processor_execution_metrics',
    metadata,
    sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False),
    sa.Column('agent_id', postgresql.UUID(as_uuid=True), nullable=True),
    sa.Column('session_id', sa.String(), nullable=False),
    sa.Column('user_id', sa.String(), nullable=False),
    sa.Column('llm_model', sa.String(), nullable=False),
    sa.Column('prompt_tokens', sa.Integer(), nullable=False),
    sa.Column('candidate_tokens', sa.Integer(), nullable=False),
    sa.Column('cost', sa.Float(), nullable=False),
    sa.Column('total_tokens', sa.Integer(), nullable=False),
    sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=True),
    sa.ForeignKeyConstraint(['agent_id'], ['evo_core_agents.id'], ondelete='CASCADE'),
    sa.PrimaryKeyConstraint('id')
)

def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        'evo_agent_processor_execution_metrics',
        sa.Column('id', postgresql.UUID(as_uuid=True), nullable=False),
        sa.Column('agent_id', postgresql.UUID(as_uuid=True), nullable=True),
        sa.Column('session_id', sa.String(), nullable=False),
        sa.Column('user_id', sa.String(), nullable=False),
        sa.Column('llm_model', sa.String(), nullable=False),
        sa.Column('prompt_tokens', sa.Integer(), nullable=False),
        sa.Column('candidate_tokens', sa.Integer(), nullable=False),
        sa.Column('cost', sa.Float(), nullable=False),
        sa.Column('total_tokens', sa.Integer(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=True),
        sa.ForeignKeyConstraint(['agent_id'], ['evo_core_agents.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id')
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_table('evo_agent_processor_execution_metrics')
