from datetime import datetime, timezone
import pytest


def test_meal_planning_basic(user_client_with_household, household_id, planned_recipe):
    """Test basic meal planning operations"""
    # Get planned meals and verify the recipe is there
    response = user_client_with_household.get(f"/api/household/{household_id}/planner")
    assert response.status_code == 200
    planned_meals = response.get_json()
    print(f"planned meals: {planned_meals}")

    assert len(planned_meals) == 1
    assert any(meal["recipe"]["id"] == planned_recipe for meal in planned_meals)


def test_meal_planning_cooking_date_field(
    user_client_with_household, household_id, planned_recipe
):
    """Test basic meal planning operations"""
    # Get planned meals and verify the recipe is there
    response = user_client_with_household.get(f"/api/household/{household_id}/planner")
    assert response.status_code == 200
    planned_meals = response.get_json()
    actual = datetime.fromtimestamp(
        planned_meals[0]["cooking_date"] / 1000, timezone.utc
    ).replace(tzinfo=None)
    expected = datetime.fromtimestamp(pytest.FIX_DATETIME / 1000, None)
    assert actual == expected


def test_meal_planning_remove_by_datetime(
    user_client_with_household, household_id, planned_recipe
):
    """Test removing meals from plan"""
    # Remove from meal plan
    response = user_client_with_household.delete(
        f"/api/household/{household_id}/planner/recipe/{planned_recipe}",
        json={"cooking_date": pytest.FIX_DATETIME},
    )
    assert response.status_code == 200

    # Verify removal
    response = user_client_with_household.get(f"/api/household/{household_id}/planner")
    assert response.status_code == 200
    planned_meals = response.get_json()
    assert not any(meal["recipe"]["id"] == planned_recipe for meal in planned_meals)


def test_recent_planned_recipes(
    user_client_with_household, household_id, planned_recipe
):
    """Test getting recently planned recipes"""
    # First remove the recipe from the plan
    response = user_client_with_household.delete(
        f"/api/household/{household_id}/planner/recipe/{planned_recipe}",
        json={"cooking_date": pytest.FIX_DATETIME},
    )
    assert response.status_code == 200

    # Now get recent recipes - should include our recently dropped recipe
    response = user_client_with_household.get(
        f"/api/household/{household_id}/planner/recent-recipes"
    )
    assert response.status_code == 200
    recent_recipes = response.get_json()
    assert len(recent_recipes) > 0
    assert any(recipe["id"] == planned_recipe for recipe in recent_recipes)


def test_suggested_recipes(user_client_with_household, household_id, recipe_with_items):
    """Test recipe suggestions functionality"""
    # Get suggested recipes
    response = user_client_with_household.get(
        f"/api/household/{household_id}/planner/suggested-recipes"
    )
    assert response.status_code == 200
    suggested_recipes = response.get_json()
    assert isinstance(suggested_recipes, list)  # Should return a list, even if empty

    # Refresh suggestions
    response = user_client_with_household.get(
        f"/api/household/{household_id}/planner/refresh-suggested-recipes"
    )
    assert response.status_code == 200
    refreshed_suggestions = response.get_json()
    assert isinstance(refreshed_suggestions, list)


def test_meal_planning_default_meal(
    user_client_with_household, household_id, planned_recipe
):
    """Plans created without a meal are stored as 'any'"""
    response = user_client_with_household.get(f"/api/household/{household_id}/planner")
    assert response.status_code == 200
    assert response.get_json()[0]["meal"] == "any"


def test_meal_planning_lunch_and_dinner_same_day(
    user_client_with_household, household_id, recipe_with_items
):
    """The same recipe can be planned for lunch and dinner of one day"""
    for meal in ("dinner", "lunch"):
        response = user_client_with_household.post(
            f"/api/household/{household_id}/planner/recipe",
            json={
                "recipe_id": recipe_with_items,
                "cooking_date": pytest.FIX_DATETIME,
                "meal": meal,
            },
        )
        assert response.status_code == 200

    response = user_client_with_household.get(f"/api/household/{household_id}/planner")
    assert response.status_code == 200
    meals = [plan["meal"] for plan in response.get_json()]
    assert meals == ["lunch", "dinner"]

    # Removing one meal keeps the other
    response = user_client_with_household.delete(
        f"/api/household/{household_id}/planner/recipe/{recipe_with_items}",
        json={"cooking_date": pytest.FIX_DATETIME, "meal": "lunch"},
    )
    assert response.status_code == 200
    response = user_client_with_household.get(f"/api/household/{household_id}/planner")
    assert [plan["meal"] for plan in response.get_json()] == ["dinner"]


def test_meal_planning_remove_without_meal_removes_whole_day(
    user_client_with_household, household_id, recipe_with_items
):
    """Older clients delete by date only: every meal of that day goes"""
    for meal in ("lunch", "dinner"):
        user_client_with_household.post(
            f"/api/household/{household_id}/planner/recipe",
            json={
                "recipe_id": recipe_with_items,
                "cooking_date": pytest.FIX_DATETIME,
                "meal": meal,
            },
        )
    response = user_client_with_household.delete(
        f"/api/household/{household_id}/planner/recipe/{recipe_with_items}",
        json={"cooking_date": pytest.FIX_DATETIME},
    )
    assert response.status_code == 200
    response = user_client_with_household.get(f"/api/household/{household_id}/planner")
    assert response.get_json() == []


def test_meal_planning_invalid_meal(
    user_client_with_household, household_id, recipe_with_items
):
    response = user_client_with_household.post(
        f"/api/household/{household_id}/planner/recipe",
        json={
            "recipe_id": recipe_with_items,
            "cooking_date": pytest.FIX_DATETIME,
            "meal": "brunch",
        },
    )
    assert response.status_code == 400
