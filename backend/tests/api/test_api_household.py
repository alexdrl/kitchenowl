import pytest


def test_get_all_households_empty(admin_client):
    response = admin_client.get(
        "/api/household",
    )
    assert response.status_code == 200
    data = response.get_json()
    assert len(data) == 0


def test_add_household_admin(admin_client, household_name):
    response = admin_client.get(
        "/api/user",
    )
    assert response.status_code == 200
    data = response.get_json()
    admin_user_id = data["id"]
    data = {"name": household_name, "member": [admin_user_id]}
    response = admin_client.post("/api/household", json=data)
    assert response.status_code == 200


def test_add_household_user(user_client, household_name):
    response = user_client.get(
        "/api/user",
    )
    assert response.status_code == 200
    data = response.get_json()
    user_id = data["id"]
    data = {"name": household_name, "member": [user_id]}
    response = user_client.post("/api/household", json=data)
    assert response.status_code == 200


def test_get_all_households(user_client_with_household, household_name):
    response = user_client_with_household.get(
        "/api/household",
    )
    assert response.status_code == 200
    data = response.get_json()
    assert len(data) == 1
    assert data[0]["name"] == household_name


def test_household_planner_breakfast_toggle(user_client_with_household, household_id):
    response = user_client_with_household.get(f"/api/household/{household_id}")
    assert response.status_code == 200
    assert response.get_json()["planner_breakfast"] is True

    response = user_client_with_household.post(
        f"/api/household/{household_id}", json={"planner_breakfast": False}
    )
    assert response.status_code == 200

    response = user_client_with_household.get(f"/api/household/{household_id}")
    assert response.get_json()["planner_breakfast"] is False
