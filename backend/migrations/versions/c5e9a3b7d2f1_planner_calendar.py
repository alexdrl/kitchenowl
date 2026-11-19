"""planner calendar: secret token for the iCalendar feed of the planner

Revision ID: c5e9a3b7d2f1
Revises: b8d4f2a6c1e3
Create Date: 2026-11-19 12:00:00.000000

"""

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision = "c5e9a3b7d2f1"
down_revision = "b8d4f2a6c1e3"
branch_labels = None
depends_on = None


def upgrade():
    op.create_table(
        "planner_calendar",
        sa.Column("household_id", sa.Integer(), nullable=False),
        sa.Column("token", sa.String(length=64), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("updated_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(
            ["household_id"],
            ["household.id"],
            name=op.f("fk_planner_calendar_household_id_household"),
        ),
        sa.PrimaryKeyConstraint("household_id", name=op.f("pk_planner_calendar")),
    )


def downgrade():
    op.drop_table("planner_calendar")
