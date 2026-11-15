from __future__ import annotations
from typing import Self, TYPE_CHECKING, cast
from app import db
from app.helpers import DbModelAuthorizeMixin
from app.models.planner import MEAL_ANY, MEALS
from sqlalchemy.orm import Mapped
from sqlalchemy import case, func
from datetime import datetime

Model = db.Model
if TYPE_CHECKING:
    from app.models import Household
    from app.helpers.db_model_base import DbModelBase

    Model = DbModelBase


class PlannerNote(Model, DbModelAuthorizeMixin):
    """A meal planned as free text instead of a recipe, e.g. "Dinner at X".

    Kept apart from Planner so clients that expect a recipe on every plan
    keep working: they simply never see notes.
    """

    __tablename__ = "planner_note"

    id: Mapped[int] = db.Column(db.Integer, primary_key=True)
    household_id: Mapped[int] = db.Column(
        db.Integer, db.ForeignKey("household.id"), nullable=False, index=True
    )
    cooking_date: Mapped[datetime] = db.Column(db.DateTime, nullable=False)
    meal: Mapped[str] = db.Column(
        db.String(16), nullable=False, default=MEAL_ANY, server_default=MEAL_ANY
    )
    text: Mapped[str] = db.Column(db.String(256), nullable=False)

    household: Mapped["Household"] = cast(
        Mapped["Household"],
        db.relationship(
            "Household",
            back_populates="planner_notes",
            uselist=False,
        ),
    )

    @classmethod
    def all_from_household(cls, household_id: int) -> list[Self]:
        return (
            cls.query.filter(cls.household_id == household_id)
            .order_by(
                cls.cooking_date,
                case(
                    {m: i for i, m in enumerate(MEALS)},
                    value=cls.meal,
                    else_=len(MEALS),
                ),
                cls.id,
            )
            .all()
        )

    @classmethod
    def recent_texts(cls, household_id: int, limit: int = 8) -> list[str]:
        """Distinct texts of the household, most recently used first"""
        rows = (
            db.session.query(cls.text, func.max(cls.updated_at).label("last"))
            .filter(cls.household_id == household_id)
            .group_by(cls.text)
            .order_by(func.max(cls.updated_at).desc())
            .limit(limit)
            .all()
        )
        return [r[0] for r in rows]
