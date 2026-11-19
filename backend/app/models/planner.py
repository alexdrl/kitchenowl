from __future__ import annotations
from typing import Any, Self, TYPE_CHECKING, cast
from app import db
from app.helpers import DbModelAuthorizeMixin
from sqlalchemy.orm import Mapped
from sqlalchemy import func, case
from datetime import datetime, date

Model = db.Model
if TYPE_CHECKING:
    from app.models import Household, Recipe
    from app.helpers.db_model_base import DbModelBase

    Model = DbModelBase


MEAL_BREAKFAST = "breakfast"
MEAL_LUNCH = "lunch"
MEAL_DINNER = "dinner"
MEAL_ANY = "any"
MEALS = (MEAL_BREAKFAST, MEAL_LUNCH, MEAL_DINNER, MEAL_ANY)


class Planner(Model, DbModelAuthorizeMixin):
    __tablename__ = "planner"

    recipe_id: Mapped[int] = db.Column(
        db.Integer, db.ForeignKey("recipe.id"), primary_key=True
    )
    cooking_date: Mapped[datetime] = db.Column(db.DateTime, primary_key=True)
    meal: Mapped[str] = db.Column(
        db.String(16),
        primary_key=True,
        nullable=False,
        default=MEAL_ANY,
        server_default=MEAL_ANY,
    )
    yields: Mapped[int] = db.Column(db.Integer)
    household_id: Mapped[int] = db.Column(
        db.Integer, db.ForeignKey("household.id"), nullable=False, index=True
    )

    household: Mapped["Household"] = cast(
        Mapped["Household"],
        db.relationship(
            "Household",
            uselist=False,
        ),
    )
    recipe: Mapped["Recipe"] = cast(
        Mapped["Recipe"],
        db.relationship(
            "Recipe",
            back_populates="plans",
        ),
    )

    def obj_to_full_dict(self) -> dict[str, Any]:
        res = self.obj_to_dict()
        res["recipe"] = self.recipe.obj_to_full_dict()
        return res

    @classmethod
    def all_from_household(cls, household_id: int) -> list[Self]:
        """
        Return all instances of model
        IMPORTANT: requires household_id column
        """
        return (
            cls.query.filter(cls.household_id == household_id)
            .order_by(
                cls.cooking_date,
                case(
                    {m: i for i, m in enumerate(MEALS)},
                    value=cls.meal,
                    else_=len(MEALS),
                ),
            )
            .all()
        )

    @classmethod
    def find_by_datetime(
        cls,
        household_id: int,
        recipe_id: int,
        cooking_date: date,
        meal: str | None = None,
    ) -> Self | None:
        return cls._query_by_date(household_id, recipe_id, cooking_date, meal).first()

    @classmethod
    def find_all_by_datetime(
        cls,
        household_id: int,
        recipe_id: int,
        cooking_date: date,
        meal: str | None = None,
    ) -> list[Self]:
        """All plans of a recipe on a day; every meal of that day when meal is None"""
        return cls._query_by_date(household_id, recipe_id, cooking_date, meal).all()

    @classmethod
    def _query_by_date(
        cls,
        household_id: int,
        recipe_id: int,
        cooking_date: date,
        meal: str | None,
    ):
        query = cls.query.filter(
            cls.household_id == household_id,
            cls.recipe_id == recipe_id,
            func.date(cls.cooking_date) == cooking_date,
        )
        if meal is not None:
            query = query.filter(cls.meal == meal)
        return query
