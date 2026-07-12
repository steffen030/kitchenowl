"""Controller-level tests for POST /api/household/{id}/recipe/filter with
ingredient include/exclude parameters."""
import pytest


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _create_recipe(client, household_id, name, items=None, tags=None):
    """Create a recipe via API; return the full recipe dict."""
    data = {
        "name": name,
        "description": "",
        "time": 0,
        "items": items or [],
        "tags": tags or [],
    }
    resp = client.post(f"/api/household/{household_id}/recipe", json=data)
    assert resp.status_code == 200, resp.get_json()
    return resp.get_json()


def _filter(client, household_id, **kwargs):
    """Call the filter endpoint and return the JSON list."""
    resp = client.post(f"/api/household/{household_id}/recipe/filter", json=kwargs)
    assert resp.status_code == 200, resp.get_json()
    return resp.get_json()


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_filter_backward_compat_no_args(
    user_client_with_household, household_id, recipe_with_items
):
    """Calling /filter with no body returns all household recipes (back-compat)."""
    results = _filter(user_client_with_household, household_id)
    ids = [r["id"] for r in results]
    assert recipe_with_items in ids


def test_filter_backward_compat_tags_only(
    user_client_with_household, household_id
):
    """Tag-only filter still works as before (back-compat)."""
    r1 = _create_recipe(
        user_client_with_household, household_id, "Tagged Recipe", tags=["breakfast"]
    )
    r2 = _create_recipe(
        user_client_with_household, household_id, "Untagged Recipe"
    )

    results = _filter(user_client_with_household, household_id, filter=["breakfast"])
    ids = [r["id"] for r in results]
    assert r1["id"] in ids
    assert r2["id"] not in ids


def test_filter_include_returns_cookable(user_client_with_household, household_id):
    """Recipe with all required items in include list has missing_count=0."""
    recipe = _create_recipe(
        user_client_with_household,
        household_id,
        "Egg Dish",
        items=[{"name": "Egg", "description": "", "optional": False}],
    )
    egg_id = recipe["items"][0]["id"]

    results = _filter(
        user_client_with_household,
        household_id,
        items_include=[egg_id],
        items_exclude=[],
        max_missing=0,
    )
    ids = [r["id"] for r in results]
    assert recipe["id"] in ids
    mc = next(r["missing_count"] for r in results if r["id"] == recipe["id"])
    assert mc == 0


def test_filter_include_missing_count_in_response(
    user_client_with_household, household_id
):
    """missing_count is present in each result when ingredient filter is active."""
    recipe = _create_recipe(
        user_client_with_household,
        household_id,
        "Missing Dish",
        items=[
            {"name": "Egg", "description": "", "optional": False},
            {"name": "Oil", "description": "", "optional": False},
        ],
    )
    egg_id = next(i["id"] for i in recipe["items"] if i["name"] == "Egg")

    # Have only Egg; Oil is missing → missing_count==1, returned with max_missing=1
    results = _filter(
        user_client_with_household,
        household_id,
        items_include=[egg_id],
        items_exclude=[],
        max_missing=1,
    )
    match = next((r for r in results if r["id"] == recipe["id"]), None)
    assert match is not None
    assert match["missing_count"] == 1


def test_filter_max_missing_excludes_too_many_missing(
    user_client_with_household, household_id
):
    """Recipe with more missing items than max_missing is excluded."""
    recipe = _create_recipe(
        user_client_with_household,
        household_id,
        "Hard Recipe",
        items=[
            {"name": "Egg", "description": "", "optional": False},
            {"name": "Oil", "description": "", "optional": False},
            {"name": "Flour", "description": "", "optional": False},
        ],
    )
    egg_id = next(i["id"] for i in recipe["items"] if i["name"] == "Egg")

    # Have only Egg (2 missing), max_missing=1 → recipe excluded
    results = _filter(
        user_client_with_household,
        household_id,
        items_include=[egg_id],
        items_exclude=[],
        max_missing=1,
    )
    ids = [r["id"] for r in results]
    assert recipe["id"] not in ids


def test_filter_exclude_hides_recipe(user_client_with_household, household_id):
    """A recipe referencing an excluded item is hidden even if otherwise cookable."""
    recipe = _create_recipe(
        user_client_with_household,
        household_id,
        "Bacon Eggs",
        items=[
            {"name": "Egg", "description": "", "optional": False},
            {"name": "Bacon", "description": "", "optional": False},
        ],
    )
    egg_id = next(i["id"] for i in recipe["items"] if i["name"] == "Egg")
    bacon_id = next(i["id"] for i in recipe["items"] if i["name"] == "Bacon")

    results = _filter(
        user_client_with_household,
        household_id,
        items_include=[egg_id, bacon_id],
        items_exclude=[bacon_id],
        max_missing=0,
    )
    ids = [r["id"] for r in results]
    assert recipe["id"] not in ids


def test_filter_exclude_only_no_have_set(user_client_with_household, household_id):
    """Exclude-only (no include_ids) hides excluded recipes; rest returned with missing_count=0."""
    recipe_with_bacon = _create_recipe(
        user_client_with_household,
        household_id,
        "Bacon Omelette",
        items=[
            {"name": "Egg", "description": "", "optional": False},
            {"name": "Bacon", "description": "", "optional": False},
        ],
    )
    recipe_egg_only = _create_recipe(
        user_client_with_household,
        household_id,
        "Plain Omelette",
        items=[{"name": "Egg", "description": "", "optional": False}],
    )
    bacon_id = next(i["id"] for i in recipe_with_bacon["items"] if i["name"] == "Bacon")

    results = _filter(
        user_client_with_household,
        household_id,
        items_include=[],
        items_exclude=[bacon_id],
        max_missing=0,
    )
    ids = [r["id"] for r in results]
    assert recipe_with_bacon["id"] not in ids
    assert recipe_egg_only["id"] in ids
    mc = next(r["missing_count"] for r in results if r["id"] == recipe_egg_only["id"])
    assert mc == 0


def test_filter_tag_and_ingredient_compose(user_client_with_household, household_id):
    """Tag filter and ingredient filter are ANDed together."""
    r_tagged = _create_recipe(
        user_client_with_household,
        household_id,
        "Breakfast Egg",
        items=[{"name": "Egg", "description": "", "optional": False}],
        tags=["breakfast"],
    )
    r_no_tag = _create_recipe(
        user_client_with_household,
        household_id,
        "Plain Egg",
        items=[{"name": "Egg", "description": "", "optional": False}],
    )
    egg_id = r_tagged["items"][0]["id"]

    results = _filter(
        user_client_with_household,
        household_id,
        items_include=[egg_id],
        items_exclude=[],
        max_missing=0,
        filter=["breakfast"],
    )
    ids = [r["id"] for r in results]
    assert r_tagged["id"] in ids
    assert r_no_tag["id"] not in ids
