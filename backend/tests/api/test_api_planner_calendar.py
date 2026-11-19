from datetime import date, datetime, timedelta, timezone

import pytest
from icalendar import Calendar

from app import app


def _ms(day: date) -> int:
    return int(
        datetime.combine(day, datetime.min.time(), tzinfo=timezone.utc).timestamp()
        * 1000
    )


@pytest.fixture
def anonymous_client():
    """A client without the JWT, like a calendar app"""
    return app.test_client()


@pytest.fixture
def calendar(user_client_with_household, household_id):
    response = user_client_with_household.post(
        f"/api/household/{household_id}/planner/calendar"
    )
    assert response.status_code == 200
    return response.get_json()


def _feed(client, path: str):
    response = client.get(path)
    assert response.status_code == 200, response.data
    assert response.headers["Content-Type"].startswith("text/calendar")
    return Calendar.from_ical(response.data)


def _events(cal: Calendar) -> dict[str, dict]:
    return {
        str(e["summary"]): {
            "uid": str(e["uid"]),
            "start": e.decoded("dtstart"),
            "end": e.decoded("dtend"),
            "description": str(e.get("description", "")),
            "transp": str(e.get("transp", "")),
        }
        for e in cal.walk("VEVENT")
    }


def test_calendar_token_lifecycle(user_client_with_household, household_id):
    base = f"/api/household/{household_id}/planner/calendar"
    assert user_client_with_household.get(base).get_json() == {
        "token": None,
        "path": None,
    }

    first = user_client_with_household.post(base).get_json()
    assert len(first["token"]) >= 40
    assert first["path"] == (
        f"/api/household/{household_id}/planner/calendar.ics?token={first['token']}"
    )
    assert user_client_with_household.get(base).get_json() == first

    # Rotating replaces the token
    second = user_client_with_household.post(base).get_json()
    assert second["token"] != first["token"]
    assert user_client_with_household.get(base).get_json() == second

    assert user_client_with_household.delete(base).status_code == 200
    assert user_client_with_household.get(base).get_json()["token"] is None


def test_calendar_token_needs_login(anonymous_client, household_id, calendar):
    base = f"/api/household/{household_id}/planner/calendar"
    assert anonymous_client.get(base).status_code == 401
    assert anonymous_client.post(base).status_code == 401


def test_calendar_feed_requires_token(anonymous_client, household_id, calendar):
    path = f"/api/household/{household_id}/planner/calendar.ics"
    assert anonymous_client.get(path).status_code == 404
    assert anonymous_client.get(f"{path}?token=").status_code == 404
    assert anonymous_client.get(f"{path}?token=wrong").status_code == 404
    assert (
        anonymous_client.get(f"{path}?token={calendar['token']}x").status_code == 404
    )
    # The token of one household does not open another one
    assert (
        anonymous_client.get(
            f"/api/household/{household_id + 1}/planner/calendar.ics"
            f"?token={calendar['token']}"
        ).status_code
        == 404
    )
    assert anonymous_client.get(calendar["path"]).status_code == 200


def test_calendar_feed_without_token_created(
    anonymous_client, user_client_with_household, household_id
):
    path = f"/api/household/{household_id}/planner/calendar.ics?token=anything"
    assert anonymous_client.get(path).status_code == 404


def test_calendar_feed_old_token_stops_working(
    anonymous_client, user_client_with_household, household_id, calendar
):
    user_client_with_household.post(f"/api/household/{household_id}/planner/calendar")
    assert anonymous_client.get(calendar["path"]).status_code == 404


def test_calendar_feed_contents(
    anonymous_client,
    user_client_with_household,
    household_id,
    recipe_with_items,
    recipe_name,
    calendar,
):
    planner = f"/api/household/{household_id}/planner"
    day = date.today() + timedelta(days=2)
    old_day = date.today() - timedelta(days=40)
    for meal, when in (("lunch", day), ("any", day), ("dinner", old_day)):
        response = user_client_with_household.post(
            f"{planner}/recipe",
            json={"recipe_id": recipe_with_items, "cooking_date": _ms(when), "meal": meal},
        )
        assert response.status_code == 200
    for meal, text in (("dinner", "Cena en casa de la abuela; postre, y café"), ("lunch", "Ensalada")):
        response = user_client_with_household.post(
            f"{planner}/notes",
            json={"cooking_date": _ms(day), "meal": meal, "text": text},
        )
        assert response.status_code == 200

    cal = _feed(anonymous_client, calendar["path"])
    events = _events(cal)

    lunch = events[f"Lunch: {recipe_name}, Ensalada"]
    assert lunch["start"] == datetime.combine(day, datetime.min.time()).replace(hour=14)
    assert lunch["end"] - lunch["start"] == timedelta(hours=1)
    assert lunch["description"] == f"{recipe_name}\nEnsalada"
    assert lunch["transp"] == "TRANSPARENT"
    assert lunch["uid"] == f"planner-{household_id}-{day:%Y%m%d}-lunch@kitchenowl"

    # Commas and semicolons survive the RFC 5545 escaping
    dinner = events["Dinner: Cena en casa de la abuela; postre, y café"]
    assert dinner["start"].hour == 21

    # A plan without a meal is an all-day event
    any_meal = events[recipe_name]
    assert any_meal["start"] == day
    assert any_meal["end"] == day + timedelta(days=1)

    # Plans older than four weeks are left out
    assert len(events) == 3
    assert all(e["uid"].endswith("@kitchenowl") for e in events.values())

    # Same plan, same output: calendar apps update events instead of adding
    raw = anonymous_client.get(calendar["path"]).data
    assert anonymous_client.get(calendar["path"]).data == raw
    # Unchanged feed: 304 for a client that sends the ETag back
    etag = anonymous_client.get(calendar["path"]).headers["ETag"]
    response = anonymous_client.get(
        calendar["path"], headers={"If-None-Match": etag}
    )
    assert response.status_code == 304
    # Lines are folded at 75 octets
    assert all(len(line) <= 75 for line in raw.split(b"\r\n"))


def test_calendar_feed_timezone_and_language(
    anonymous_client,
    user_client_with_household,
    household_id,
    recipe_with_items,
    recipe_name,
    calendar,
):
    user_client_with_household.post(
        f"/api/household/{household_id}", json={"language": "es"}
    )
    day = date.today() + timedelta(days=1)
    user_client_with_household.post(
        f"/api/household/{household_id}/planner/recipe",
        json={"recipe_id": recipe_with_items, "cooking_date": _ms(day), "meal": "dinner"},
    )

    cal = _feed(anonymous_client, calendar["path"] + "&tz=Europe/Madrid")
    assert str(cal["x-wr-timezone"]) == "Europe/Madrid"
    assert [str(tz["tzid"]) for tz in cal.walk("VTIMEZONE")] == ["Europe/Madrid"]
    event = _events(cal)[f"Cena: {recipe_name}"]
    assert event["start"].tzinfo is not None
    assert str(event["start"].tzinfo) == "Europe/Madrid"
    assert event["start"].hour == 21

    assert anonymous_client.get(calendar["path"] + "&tz=Nowhere/Land").status_code == 400
