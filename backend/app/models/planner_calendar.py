from __future__ import annotations
import hmac
import secrets
from typing import Self, TYPE_CHECKING, cast
from app import db
from sqlalchemy.orm import Mapped

Model = db.Model
if TYPE_CHECKING:
    from app.models import Household
    from app.helpers.db_model_base import DbModelBase

    Model = DbModelBase


class PlannerCalendar(Model):
    """Secret that lets calendar apps read a household's planner as iCalendar.

    Calendar apps cannot send the JWT, so the feed URL carries this token.
    It lives in its own table, not on Household, so it never ends up in the
    household JSON that every member and socket event receives.
    """

    __tablename__ = "planner_calendar"

    household_id: Mapped[int] = db.Column(
        db.Integer, db.ForeignKey("household.id"), primary_key=True
    )
    token: Mapped[str] = db.Column(db.String(64), nullable=False)

    household: Mapped["Household"] = cast(
        Mapped["Household"],
        db.relationship(
            "Household",
            back_populates="planner_calendar",
            uselist=False,
        ),
    )

    @staticmethod
    def new_token() -> str:
        # 32 random bytes, 43 URL-safe characters
        return secrets.token_urlsafe(32)

    @classmethod
    def find_by_household(cls, household_id: int) -> Self | None:
        return cls.query.filter(cls.household_id == household_id).first()

    @classmethod
    def rotate(cls, household_id: int) -> Self:
        """Creates the household's token, or replaces it with a new one"""
        calendar = cls.find_by_household(household_id)
        if not calendar:
            calendar = cls()
            calendar.household_id = household_id
        calendar.token = cls.new_token()
        calendar.save()
        return calendar

    def matches(self, token: str | None) -> bool:
        if not token:
            return False
        # Constant time, so response timing does not leak the token
        return hmac.compare_digest(self.token.encode(), token.encode())
