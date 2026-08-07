"""Adjuntos de nota: capturas de graficos y capa de dibujo

Revision ID: e88e79352650
Revises: d4e28b5c1f73
Create Date: 2026-08-07 14:54:34.313768

"""

from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "e88e79352650"
down_revision: str | Sequence[str] | None = "d4e28b5c1f73"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "note_attachments",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("note_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("ticker", sa.String(length=20), nullable=True),
        # Los bytes crudos de la imagen, no su base64: el cliente la manda codificada porque el
        # cuerpo es JSON, pero guardarla así desperdiciaría un 33% del espacio para siempre.
        sa.Column("image_bytes", sa.LargeBinary(), nullable=False),
        sa.Column("content_type", sa.String(length=64), nullable=False),
        # Aparte de la imagen justamente porque la columna del blob es `deferred`: el listado tiene
        # que poder decir "820 KB" sin traerse los 820 KB.
        sa.Column("byte_size", sa.Integer(), nullable=False),
        sa.Column("width", sa.Integer(), nullable=True),
        sa.Column("height", sa.Integer(), nullable=True),
        sa.Column("caption", sa.String(length=300), nullable=True),
        sa.Column("source", sa.String(length=64), nullable=True),
        # La capa vectorial (líneas, rectángulos, textos) en coordenadas normalizadas 0..1. JSON y no
        # una tabla de formas: se lee y se reescribe siempre entera, y normalizarla obligaría a un
        # DELETE + INSERT masivo en cada trazo.
        sa.Column("drawing_data", sa.JSON(), nullable=False),
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
        # `CASCADE` acá SÍ corresponde, al revés que en `folders`: un adjunto no significa nada sin su
        # nota y no hay ningún lugar razonable al que reparentarlo.
        sa.ForeignKeyConstraint(["note_id"], ["notes.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        op.f("ix_note_attachments_note_id"),
        "note_attachments",
        ["note_id"],
        unique=False,
    )
    op.create_index(
        op.f("ix_note_attachments_ticker"),
        "note_attachments",
        ["ticker"],
        unique=False,
    )
    op.create_index(
        op.f("ix_note_attachments_user_id"),
        "note_attachments",
        ["user_id"],
        unique=False,
    )


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_note_attachments_user_id"), table_name="note_attachments")
    op.drop_index(op.f("ix_note_attachments_ticker"), table_name="note_attachments")
    op.drop_index(op.f("ix_note_attachments_note_id"), table_name="note_attachments")
    op.drop_table("note_attachments")
