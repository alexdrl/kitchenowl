"""iCalendar (RFC 5545) feed of a household's planner.

One event per day and meal ("slot"). Every recipe and text note planned
for that slot goes into the same event: a calendar month view has room for
about three events per day, so lunch and dinner stay visible, and the agenda
view lists the day in meal order. The UID depends only on household, day and
meal, so a calendar app updates an existing event when the plan changes and
never duplicates it.

Breakfast, lunch and dinner are timed events (default 08:30, 14:00 and 21:00,
see PLANNER_CALENDAR_MEAL_TIMES), because calendar apps sort timed events by
time but all-day events alphabetically. They are marked transparent, so they
never show the user as busy. Plans without a meal ("any") are all-day events.

Times are in the timezone given by the feed URL (?tz=Europe/Madrid), else in
PLANNER_CALENDAR_TIMEZONE or TZ. Without any of these they are floating
times: 14:00 wherever the reader is.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass, field
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from icalendar import Calendar, Event

from app.errors import InvalidUsage
from app.models import Household, Planner, PlannerNote
from app.models.planner import (
    MEAL_ANY,
    MEAL_BREAKFAST,
    MEAL_DINNER,
    MEAL_LUNCH,
    MEALS,
)

logger = logging.getLogger(__name__)

# Past days kept in the feed. Future plans are all included.
PAST_DAYS = 28
REFRESH_INTERVAL = timedelta(hours=1)  # PT1H

_DEFAULT_MEAL_TIMES: dict[str, tuple[time, timedelta]] = {
    MEAL_BREAKFAST: (time(8, 30), timedelta(minutes=30)),
    MEAL_LUNCH: (time(14, 0), timedelta(hours=1)),
    MEAL_DINNER: (time(21, 0), timedelta(hours=1)),
}

_LABELS = {
    "en": {
        MEAL_BREAKFAST: "Breakfast",
        MEAL_LUNCH: "Lunch",
        MEAL_DINNER: "Dinner",
        "calendar": "Meal plan",
    },
    "es": {
        MEAL_BREAKFAST: "Desayuno",
        MEAL_LUNCH: "Comida",
        MEAL_DINNER: "Cena",
        "calendar": "Menú",
    },
    "de": {
        MEAL_BREAKFAST: "Frühstück",
        MEAL_LUNCH: "Mittagessen",
        MEAL_DINNER: "Abendessen",
        "calendar": "Essensplan",
    },
}


def _parse_meal_times(value: str | None) -> dict[str, tuple[time, timedelta]]:
    """PLANNER_CALENDAR_MEAL_TIMES, e.g. "breakfast=08:00,lunch=13:30"."""
    times = dict(_DEFAULT_MEAL_TIMES)
    for entry in (value or "").split(","):
        if not entry.strip():
            continue
        meal, _, start = entry.partition("=")
        meal = meal.strip()
        try:
            parsed = time.fromisoformat(start.strip())
        except ValueError:
            parsed = None
        if meal not in times or parsed is None:
            logger.warning("Ignoring PLANNER_CALENDAR_MEAL_TIMES entry %r", entry)
            continue
        times[meal] = (parsed, times[meal][1])
    return times


MEAL_TIMES = _parse_meal_times(os.getenv("PLANNER_CALENDAR_MEAL_TIMES"))


def _zone(name: str | None) -> ZoneInfo | None:
    if not name:
        return None
    try:
        return ZoneInfo(name)
    except ZoneInfoNotFoundError, ValueError:
        return None


def resolve_timezone(requested: str | None) -> ZoneInfo | None:
    """Timezone of the feed; None means floating times."""
    if requested:
        zone = _zone(requested)
        if zone is None:
            raise InvalidUsage("Unknown timezone")
        return zone
    return _zone(os.getenv("PLANNER_CALENDAR_TIMEZONE")) or _zone(os.getenv("TZ"))


@dataclass
class _Slot:
    day: date
    meal: str
    titles: list[str] = field(default_factory=list)
    updated: datetime | None = None

    def touch(self, updated_at: datetime | None):
        if updated_at is None:
            return
        if updated_at.tzinfo is None:
            updated_at = updated_at.replace(tzinfo=timezone.utc)
        if self.updated is None or updated_at > self.updated:
            self.updated = updated_at


def _labels(household: Household) -> dict[str, str]:
    language = (household.language or "en").split("_")[0].split("-")[0].lower()
    return _LABELS.get(language, _LABELS["en"])


def _collect_slots(household_id: int, since: date) -> list[_Slot]:
    since_dt = datetime.combine(since, time.min)
    slots: dict[tuple[date, str], _Slot] = {}

    def slot(day: date, meal: str) -> _Slot:
        meal = meal if meal in MEALS else MEAL_ANY
        key = (day, meal)
        if key not in slots:
            slots[key] = _Slot(day, meal)
        return slots[key]

    plans = (
        Planner.query.filter(
            Planner.household_id == household_id,
            Planner.cooking_date >= since_dt,
        )
        .order_by(Planner.cooking_date)
        .all()
    )
    for plan in plans:
        s = slot(plan.cooking_date.date(), plan.meal)
        s.titles.append(plan.recipe.name)
        s.touch(plan.updated_at)
    for note in PlannerNote.all_from_household(household_id, since_dt):
        s = slot(note.cooking_date.date(), note.meal)
        s.titles.append(note.text)
        s.touch(note.updated_at)

    meal_order = {m: i for i, m in enumerate(MEALS)}
    return sorted(slots.values(), key=lambda s: (s.day, meal_order[s.meal]))


def _event(
    household: Household,
    slot: _Slot,
    labels: dict[str, str],
    zone: ZoneInfo | None,
    stamp: datetime,
) -> Event:
    event = Event()
    event.add("uid", f"planner-{household.id}-{slot.day:%Y%m%d}-{slot.meal}@kitchenowl")
    event.add("dtstamp", slot.updated or stamp)
    if slot.updated:
        event.add("last-modified", slot.updated)

    names = ", ".join(slot.titles)
    if slot.meal in MEAL_TIMES:
        start_time, duration = MEAL_TIMES[slot.meal]
        start = datetime.combine(slot.day, start_time)
        if zone is not None:
            start = start.replace(tzinfo=zone)
        event.add("summary", f"{labels[slot.meal]}: {names}")
        event.add("dtstart", start)
        event.add("dtend", start + duration)
    else:
        event.add("summary", names)
        event.add("dtstart", slot.day)
        event.add("dtend", slot.day + timedelta(days=1))
    if len(slot.titles) > 1:
        event.add("description", "\n".join(slot.titles))
    # A meal plan never makes anyone busy
    event.add("transp", "TRANSPARENT")
    return event


def build_calendar(household: Household, zone: ZoneInfo | None) -> bytes:
    now = datetime.now(timezone.utc)
    today = now.astimezone(zone).date() if zone else datetime.now().date()
    labels = _labels(household)

    cal = Calendar()
    cal.add("prodid", "-//KitchenOwl//Planner//EN")
    cal.add("version", "2.0")
    cal.add("calscale", "GREGORIAN")
    cal.add("method", "PUBLISH")
    name = f"{household.name} · {labels['calendar']}"
    cal.add("name", name)
    cal.add("x-wr-calname", name)
    cal.add("refresh-interval", REFRESH_INTERVAL, parameters={"VALUE": "DURATION"})
    cal.add("x-published-ttl", "PT1H")
    if zone is not None:
        cal.add("x-wr-timezone", zone.key)

    since = today - timedelta(days=PAST_DAYS)
    slots = _collect_slots(household.id, since)
    for slot in slots:
        cal.add_component(_event(household, slot, labels, zone, now))

    if zone is not None:
        # Only the transitions the feed needs, not 1970 to 2038
        last = max([today, *(s.day for s in slots)]) + timedelta(days=366)
        cal.add_missing_timezones(first_date=since, last_date=last)
    return cal.to_ical()
