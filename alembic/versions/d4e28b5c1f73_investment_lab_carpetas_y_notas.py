"""Investment Lab: carpetas y notas

Revision ID: d4e28b5c1f73
Revises: c3d17a4b9e52
Create Date: 2026-08-06 09:41:22.117433

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "d4e28b5c1f73"
down_revision: str | Sequence[str] | None = "c3d17a4b9e52"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "folders",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("name", sa.String(length=120), nullable=False),
        sa.Column("parent_id", sa.Uuid(), nullable=True),
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
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        # `SET NULL` y no CASCADE en la autoreferencia: borrar una carpeta no puede llevarse su
        # subárbol por decisión de la base. La política de borrado (reparentar por defecto, cascada
        # solo si se pide) la decide `app/services/notes_service.py`, y un CASCADE acá haría que un
        # DELETE directo en SQL destruyera notas sin pasar por esa decisión.
        sa.ForeignKeyConstraint(["parent_id"], ["folders.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_folders_user_id"), "folders", ["user_id"], unique=False)
    op.create_index(
        op.f("ix_folders_parent_id"), "folders", ["parent_id"], unique=False
    )

    op.create_table(
        "notes",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("folder_id", sa.Uuid(), nullable=True),
        sa.Column("ticker", sa.String(length=20), nullable=True),
        sa.Column("title", sa.String(length=200), nullable=False),
        sa.Column("content", sa.Text(), nullable=False),
        sa.Column("pinned", sa.Boolean(), nullable=False),
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
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        # `SET NULL`: una nota sin carpeta es un estado normal (la raíz del Lab), y es a dónde van
        # las notas cuando su carpeta se borra sin cascada. Un CASCADE acá convertiría "borré una
        # carpeta" en "perdí las notas".
        sa.ForeignKeyConstraint(["folder_id"], ["folders.id"], ondelete="SET NULL"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(op.f("ix_notes_user_id"), "notes", ["user_id"], unique=False)
    op.create_index(op.f("ix_notes_folder_id"), "notes", ["folder_id"], unique=False)
    op.create_index(op.f("ix_notes_ticker"), "notes", ["ticker"], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_notes_ticker"), table_name="notes")
    op.drop_index(op.f("ix_notes_folder_id"), table_name="notes")
    op.drop_index(op.f("ix_notes_user_id"), table_name="notes")
    op.drop_table("notes")
    op.drop_index(op.f("ix_folders_parent_id"), table_name="folders")
    op.drop_index(op.f("ix_folders_user_id"), table_name="folders")
    op.drop_table("folders")
