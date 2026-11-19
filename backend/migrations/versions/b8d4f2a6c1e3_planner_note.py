"""planner notes: meals planned as free text

Revision ID: b8d4f2a6c1e3
Revises: a7c3e9d1b2f4
Create Date: 2026-11-15 12:00:00.000000

"""

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision = "b8d4f2a6c1e3"
down_revision = "a7c3e9d1b2f4"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "planner_note",
        sa.Column("id", sa.Integer(), nullable=False),
        sa.Column("household_id", sa.Integer(), nullable=False),
        sa.Column("cooking_date", sa.DateTime(), nullable=False),
        sa.Column(
            "meal", sa.String(length=16), nullable=False, server_default="any"
        ),
        sa.Column("text", sa.String(length=256), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ["household_id"],
            ["household.id"],
            name=op.f("fk_planner_note_household_id_household"),
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_planner_note")),
    )
    with op.batch_alter_table("planner_note", schema=None) as batch_op:
        batch_op.create_index(
            batch_op.f("ix_planner_note_household_id"), ["household_id"], unique=False
        )


def downgrade():
    with op.batch_alter_table("planner_note", schema=None) as batch_op:
        batch_op.drop_index(batch_op.f("ix_planner_note_household_id"))
    op.drop_table("planner_note")
