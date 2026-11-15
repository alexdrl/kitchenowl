"""meal (breakfast, lunch, dinner) in planner, household breakfast toggle

Revision ID: a7c3e9d1b2f4
Revises: c2e936c8ab31
Create Date: 2026-11-15 10:30:00.000000

"""

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision = "a7c3e9d1b2f4"
down_revision = "c2e936c8ab31"
branch_labels = None
depends_on = None


def upgrade():
    with op.batch_alter_table("household", schema=None) as batch_op:
        batch_op.add_column(
            sa.Column(
                "planner_breakfast",
                sa.Boolean(),
                nullable=False,
                server_default=sa.true(),
            )
        )

    with op.batch_alter_table("planner", schema=None) as batch_op:
        batch_op.add_column(
            sa.Column(
                "meal",
                sa.String(length=16),
                nullable=False,
                server_default="any",
            )
        )
        batch_op.drop_constraint("pk_planner")
        batch_op.create_primary_key(
            "pk_planner", ["recipe_id", "cooking_date", "meal"]
        )


def downgrade():
    # Keep one plan per recipe and day before shrinking the primary key
    op.execute(
        """
        DELETE FROM planner
        WHERE meal <> 'any'
          AND EXISTS (
            SELECT 1 FROM planner p2
            WHERE p2.recipe_id = planner.recipe_id
              AND p2.cooking_date = planner.cooking_date
              AND p2.meal = 'any'
          )
        """
    )
    op.execute(
        """
        DELETE FROM planner
        WHERE meal <> 'any'
          AND meal NOT IN (
            SELECT MIN(p2.meal) FROM planner p2
            WHERE p2.recipe_id = planner.recipe_id
              AND p2.cooking_date = planner.cooking_date
          )
        """
    )
    with op.batch_alter_table("planner", schema=None) as batch_op:
        batch_op.drop_constraint("pk_planner")
        batch_op.create_primary_key("pk_planner", ["recipe_id", "cooking_date"])
        batch_op.drop_column("meal")

    with op.batch_alter_table("household", schema=None) as batch_op:
        batch_op.drop_column("planner_breakfast")
