from app.errors import NotFoundRequest
from flask import jsonify, Blueprint, request, make_response
from flask_jwt_extended import jwt_required
from app import db
from app.helpers import validate_args, authorize_household
from app.models import (
    Household,
    Recipe,
    RecipeHistory,
    Planner,
    PlannerNote,
    PlannerCalendar,
)
from app.models.planner import MEAL_ANY
from app.service.planner_calendar import build_calendar, resolve_timezone
from .schemas import (
    AddPlannedRecipe,
    AddPlannerNote,
    RemovePlannedRecipe,
    UpdatePlannerNote,
)
from datetime import datetime, timedelta, timezone, date


plannerHousehold = Blueprint("planner", __name__)


def is_within_next_7_days(target_date: date) -> bool:
    # Get the current date and time
    now = datetime.now().date()

    # Calculate the date 7 days from now
    seven_days_later = now + timedelta(days=7)

    # Check if the target date is within the next 7 days
    return now <= target_date <= seven_days_later


def transform_cooking_date_to_day(cooking_date: date) -> int:
    if is_within_next_7_days(cooking_date):
        return cooking_date.weekday()
    return -1


def next_weekday(weekday_number: int) -> date:
    # Get today's date
    today = datetime.now().date()

    # Calculate how many days to add to get to the next specified weekday
    days_ahead = (weekday_number - today.weekday() + 7) % 7

    # Calculate the next weekday date
    next_date = today + timedelta(days=days_ahead)

    return next_date


@plannerHousehold.route("/recipes", methods=["GET"])
@jwt_required()
@authorize_household()
def getAllPlannedRecipes(household_id):
    plannedRecipes = (
        db.session.query(Planner.recipe_id)
        .filter(Planner.household_id == household_id)
        .group_by(Planner.recipe_id)
        .scalar_subquery()
    )
    recipes = (
        Recipe.query.filter(Recipe.id.in_(plannedRecipes)).order_by(Recipe.name).all()
    )
    return jsonify([e.obj_to_full_dict() for e in recipes])


@plannerHousehold.route("", methods=["GET"])
@jwt_required()
@authorize_household()
def getPlanner(household_id):
    plans = Planner.all_from_household(household_id)
    k = [e.obj_to_full_dict() for e in plans]
    # add day for backwards compatibility
    for d in k:
        d["day"] = transform_cooking_date_to_day(d["cooking_date"].date())
    return jsonify(k)


@plannerHousehold.route("/recipe", methods=["POST"])
@jwt_required()
@authorize_household()
@validate_args(AddPlannedRecipe)
def addPlannedRecipe(args, household_id):
    recipe = Recipe.find_by_id(args["recipe_id"])
    if not recipe:
        raise NotFoundRequest()
    recipe.checkAuthorized()
    cooking_date = (
        datetime.fromtimestamp(args["cooking_date"] / 1000, timezone.utc).date()
        if "cooking_date" in args
        else date.min
    )
    if "day" in args:
        # if outdated "day" was used, transform it into next date with that weekday
        cooking_date = next_weekday(args["day"])
    meal = args.get("meal", MEAL_ANY)
    if args.get("move"):
        return _move_planned_recipe(args, household_id, recipe, cooking_date, meal)
    planner = Planner.find_by_datetime(
        household_id=household_id,
        recipe_id=recipe.id,
        cooking_date=cooking_date,
        meal=meal,
    )
    if not planner:
        if cooking_date > date.min:
            old = Planner.find_by_datetime(
                household_id, recipe_id=recipe.id, cooking_date=date.min
            )
            if old:
                old.delete()
        elif len(recipe.plans) > 0:
            return jsonify(recipe.obj_to_dict())
        planner = Planner()
        planner.recipe_id = recipe.id
        planner.household_id = household_id
        planner.cooking_date = datetime.combine(cooking_date, datetime.min.time())
        planner.meal = meal
        if "yields" in args:
            planner.yields = args["yields"]
        planner.save()

        RecipeHistory.create_added(recipe, household_id)

    return jsonify(recipe.obj_to_dict())


def _move_planned_recipe(args, household_id, recipe, cooking_date, meal):
    """Moves a plan to another day/meal in one commit, without recording
    it as dropped and re-added in the recipe history."""
    from_date = (
        datetime.fromtimestamp(args["from_cooking_date"] / 1000, timezone.utc).date()
        if "from_cooking_date" in args
        else date.min
    )
    from_meal = args.get("from_meal", MEAL_ANY)
    source = Planner.find_by_datetime(
        household_id, recipe_id=recipe.id, cooking_date=from_date, meal=from_meal
    )
    target = Planner.find_by_datetime(
        household_id, recipe_id=recipe.id, cooking_date=cooking_date, meal=meal
    )
    if source and source is not target:
        db.session.delete(source)
    if not target:
        target = Planner()
        target.recipe_id = recipe.id
        target.household_id = household_id
        target.cooking_date = datetime.combine(cooking_date, datetime.min.time())
        target.meal = meal
        if "yields" in args:
            target.yields = args["yields"]
        elif source:
            target.yields = source.yields
        db.session.add(target)
    db.session.commit()
    return jsonify(recipe.obj_to_dict())


@plannerHousehold.route("/recipe/<int:id>", methods=["DELETE"])
@jwt_required()
@authorize_household()
@validate_args(RemovePlannedRecipe)
def removePlannedRecipeById(args, household_id, id):
    recipe = Recipe.find_by_id(id)
    if not recipe:
        raise NotFoundRequest()

    cooking_date = (
        datetime.fromtimestamp(args["cooking_date"] / 1000, timezone.utc).date()
        if "cooking_date" in args
        else date.min
    )
    if "day" in args:
        # if outdated "day" was used, transform it into next date with that weekday
        cooking_date = next_weekday(args["day"])
    # Without "meal" (older clients) every plan of that day is removed
    plans = Planner.find_all_by_datetime(
        household_id,
        recipe_id=recipe.id,
        cooking_date=cooking_date,
        meal=args.get("meal"),
    )
    for planner in plans:
        planner.delete()
    if plans:
        RecipeHistory.create_dropped(recipe, household_id)
    return jsonify(recipe.obj_to_dict())


@plannerHousehold.route("/recent-recipes", methods=["GET"], defaults={"page": 0})
@plannerHousehold.route("/recent-recipes/<int:page>", methods=["GET"])
@jwt_required()
@authorize_household()
def getRecentRecipes(household_id, page):
    recipes = RecipeHistory.get_recent(household_id, page)
    return jsonify([e.recipe.obj_to_full_dict() for e in recipes])


@plannerHousehold.route("/suggested-recipes", methods=["GET"], defaults={"page": 0})
@plannerHousehold.route("/suggested-recipes/<int:page>", methods=["GET"])
@jwt_required()
@authorize_household()
def getSuggestedRecipes(household_id, page):
    # all suggestions
    suggested_recipes = Recipe.find_suggestions(household_id, page)
    # remove recipes on recent list
    # recents = [e.recipe.id for e in RecipeHistory.get_recent(household_id)]
    # suggested_recipes = [s for s in suggested_recipes if s.id not in recents]
    return jsonify([r.obj_to_full_dict() for r in suggested_recipes])


@plannerHousehold.route("/refresh-suggested-recipes", methods=["GET", "POST"])
@jwt_required()
@authorize_household()
def getRefreshedSuggestedRecipes(household_id):
    # re-compute suggestion ranking
    Recipe.compute_suggestion_ranking(household_id)
    # return suggested recipes
    return getSuggestedRecipes(household_id=household_id, page=0)


def _note_date(timestamp_ms: int) -> datetime:
    day = datetime.fromtimestamp(timestamp_ms / 1000, timezone.utc).date()
    return datetime.combine(day, datetime.min.time())


def _find_note(household_id: int, id: int) -> PlannerNote:
    note = PlannerNote.find_by_id(id)
    if not note or note.household_id != household_id:
        raise NotFoundRequest()
    return note


@plannerHousehold.route("/notes", methods=["GET"])
@jwt_required()
@authorize_household()
def getPlannerNotes(household_id):
    # Optional ?from=<ms>: only notes on or after that day
    since = request.args.get("from", type=int)
    return jsonify(
        [
            n.obj_to_dict()
            for n in PlannerNote.all_from_household(
                household_id, _note_date(since) if since is not None else None
            )
        ]
    )


@plannerHousehold.route("/notes/recent", methods=["GET"])
@jwt_required()
@authorize_household()
def getRecentPlannerNoteTexts(household_id):
    return jsonify(PlannerNote.recent_texts(household_id))


@plannerHousehold.route("/notes", methods=["POST"])
@jwt_required()
@authorize_household()
@validate_args(AddPlannerNote)
def addPlannerNote(args, household_id):
    note = PlannerNote()
    note.household_id = household_id
    note.cooking_date = _note_date(args["cooking_date"])
    note.meal = args.get("meal", MEAL_ANY)
    note.text = args["text"].strip()
    note.save()
    return jsonify(note.obj_to_dict())


@plannerHousehold.route("/notes/<int:id>", methods=["POST"])
@jwt_required()
@authorize_household()
@validate_args(UpdatePlannerNote)
def updatePlannerNote(args, household_id, id):
    note = _find_note(household_id, id)
    if "cooking_date" in args:
        note.cooking_date = _note_date(args["cooking_date"])
    if "meal" in args:
        note.meal = args["meal"]
    if "text" in args:
        note.text = args["text"].strip()
    note.save()
    return jsonify(note.obj_to_dict())


@plannerHousehold.route("/notes/<int:id>", methods=["DELETE"])
@jwt_required()
@authorize_household()
def deletePlannerNote(household_id, id):
    _find_note(household_id, id).delete()
    return jsonify({"msg": "DONE"})


def _calendar_dict(household_id: int, calendar: PlannerCalendar | None):
    if not calendar:
        return {"token": None, "path": None}
    # Relative to the server root: request.url_root is wrong behind a proxy
    return {
        "token": calendar.token,
        "path": f"/api/household/{household_id}/planner/calendar.ics"
        f"?token={calendar.token}",
    }


@plannerHousehold.route("/calendar", methods=["GET"])
@jwt_required()
@authorize_household()
def getPlannerCalendar(household_id):
    return jsonify(
        _calendar_dict(household_id, PlannerCalendar.find_by_household(household_id))
    )


@plannerHousehold.route("/calendar", methods=["POST"])
@jwt_required()
@authorize_household()
def rotatePlannerCalendar(household_id):
    """Creates the calendar link, or replaces it: the old link stops working"""
    return jsonify(_calendar_dict(household_id, PlannerCalendar.rotate(household_id)))


@plannerHousehold.route("/calendar", methods=["DELETE"])
@jwt_required()
@authorize_household()
def deletePlannerCalendar(household_id):
    calendar = PlannerCalendar.find_by_household(household_id)
    if calendar:
        calendar.delete()
    return jsonify({"msg": "DONE"})


@plannerHousehold.route("/calendar.ics", methods=["GET"])
def getPlannerCalendarFeed(household_id):
    """iCalendar feed for calendar apps, which cannot send the JWT.

    The token in the query string is the only credential. Every failure is
    a plain 404, so the response does not tell whether the household exists.
    """
    calendar = PlannerCalendar.find_by_household(household_id)
    if not calendar or not calendar.matches(request.args.get("token")):
        raise NotFoundRequest()
    household = Household.find_by_id(household_id)
    if not household:
        raise NotFoundRequest()
    zone = resolve_timezone(request.args.get("tz"))
    response = make_response(build_calendar(household, zone))
    response.headers["Content-Type"] = "text/calendar; charset=utf-8"
    response.headers["Content-Disposition"] = 'inline; filename="kitchenowl.ics"'
    response.headers["Cache-Control"] = "private, max-age=300"
    response.headers["Referrer-Policy"] = "no-referrer"
    # Lets ICSx⁵ and others skip unchanged downloads (304)
    response.add_etag()
    return response.make_conditional(request)
