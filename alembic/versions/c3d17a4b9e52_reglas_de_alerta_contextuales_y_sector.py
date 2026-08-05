"""Reglas de alerta contextuales y sector en el catalogo de tickers

Revision ID: c3d17a4b9e52
Revises: 8f91a9a270b4
Create Date: 2026-08-05 11:12:03.418772

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c3d17a4b9e52"
down_revision: str | Sequence[str] | None = "8f91a9a270b4"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "watchlist_alert_rules",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("watchlist_item_id", sa.Uuid(), nullable=False),
        sa.Column(
            "alert_type",
            sa.Enum(
                "PRICE",
                "NEWS_SEVERITY",
                "TREND_BREAK",
                name="alertruletype",
                native_enum=False,
                length=24,
            ),
            nullable=False,
        ),
        sa.Column("enabled", sa.Boolean(), nullable=False),
        sa.Column("threshold_pct", sa.Numeric(precision=5, scale=2), nullable=True),
        sa.Column(
            "min_severity",
            sa.Enum(
                "LOW",
                "MEDIUM",
                "HIGH",
                "CRITICAL",
                name="alertseverity",
                native_enum=False,
                length=16,
            ),
            nullable=True,
        ),
        sa.Column("require_negative_sentiment", sa.Boolean(), nullable=False),
        sa.Column(
            "trend_horizon",
            sa.Enum(
                "CORTO",
                "MEDIANO",
                "LARGO",
                name="trendhorizon",
                native_enum=False,
                length=16,
            ),
            nullable=True,
        ),
        sa.Column(
            "trend_direction",
            sa.Enum(
                "BAJISTA",
                "ALCISTA",
                "CUALQUIERA",
                name="trendbreakdirection",
                native_enum=False,
                length=16,
            ),
            nullable=True,
        ),
        sa.Column(
            "min_probability_pct", sa.Numeric(precision=5, scale=2), nullable=True
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("(CURRENT_TIMESTAMP)"),
            nullable=False,
        ),
        sa.ForeignKeyConstraint(
            ["watchlist_item_id"], ["watchlists.id"], ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint(
            "watchlist_item_id", "alert_type", name="uq_alert_rule_item_type"
        ),
    )
    op.create_index(
        op.f("ix_watchlist_alert_rules_watchlist_item_id"),
        "watchlist_alert_rules",
        ["watchlist_item_id"],
        unique=False,
    )
    op.add_column("tickers", sa.Column("sector", sa.String(length=64), nullable=True))


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_column("tickers", "sector")
    op.drop_index(
        op.f("ix_watchlist_alert_rules_watchlist_item_id"),
        table_name="watchlist_alert_rules",
    )
    op.drop_table("watchlist_alert_rules")
