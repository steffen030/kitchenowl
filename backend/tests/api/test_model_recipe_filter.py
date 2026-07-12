"""Model-level tests for Recipe.filter_by_items()."""
import pytest
from app import db
from app.models.household import Household
from app.models.item import Item
from app.models.tag import Tag
from app.models.recipe import Recipe, RecipeItems, RecipeTags


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def household(client):
    h = Household(name="Filter Test Household")
    db.session.add(h)
    db.session.commit()
    return h


@pytest.fixture
def items(household):
    egg = Item(name="Egg", household_id=household.id)
    oil = Item(name="Oil", household_id=household.id)
    apple = Item(name="Apple", household_id=household.id)
    bacon = Item(name="Bacon", household_id=household.id)
    db.session.add_all([egg, oil, apple, bacon])
    db.session.commit()
    return {"egg": egg, "oil": oil, "apple": apple, "bacon": bacon}


def _make_recipe(household_id, name, required=(), optional=()):
    """Create a recipe and attach required / optional items."""
    r = Recipe(
        name=name,
        description="",
        household_id=household_id,
        time=0,
        cook_time=0,
        prep_time=0,
        yields=0,
        source="",
    )
    db.session.add(r)
    db.session.flush()
    for item in required:
        db.session.add(
            RecipeItems(recipe_id=r.id, item_id=item.id, optional=False, description="")
        )
    for item in optional:
        db.session.add(
            RecipeItems(recipe_id=r.id, item_id=item.id, optional=True, description="")
        )
    db.session.commit()
    return r


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_cookable_when_all_required_included(client, household, items):
    """Recipe is cookable (missing_count==0) when all required items are provided."""
    egg, oil = items["egg"], items["oil"]
    recipe = _make_recipe(household.id, "Fried Egg", required=[egg, oil])

    results = Recipe.filter_by_items(
        household.id,
        include_ids=[egg.id, oil.id],
        exclude_ids=[],
        tags=[],
        max_missing=0,
    )
    ids = [r.id for r, _ in results]
    assert recipe.id in ids
    mc = next(mc for r, mc in results if r.id == recipe.id)
    assert mc == 0


def test_missing_count_within_threshold(client, household, items):
    """Recipe appears when missing_count <= max_missing."""
    egg, oil = items["egg"], items["oil"]
    recipe = _make_recipe(household.id, "Egg Dish", required=[egg, oil])

    # Have egg but not oil — missing_count == 1
    results = Recipe.filter_by_items(
        household.id,
        include_ids=[egg.id],
        exclude_ids=[],
        tags=[],
        max_missing=1,
    )
    ids = [r.id for r, _ in results]
    assert recipe.id in ids
    mc = next(mc for r, mc in results if r.id == recipe.id)
    assert mc == 1


def test_missing_count_exceeds_threshold(client, household, items):
    """Recipe is excluded when missing_count > max_missing (with a non-empty have-set)."""
    egg, oil = items["egg"], items["oil"]
    recipe = _make_recipe(household.id, "Egg Dish 2", required=[egg, oil])

    # Have only egg; oil is missing → missing_count==1; max_missing==0 → excluded
    results = Recipe.filter_by_items(
        household.id,
        include_ids=[egg.id],
        exclude_ids=[],
        tags=[],
        max_missing=0,
    )
    ids = [r.id for r, _ in results]
    assert recipe.id not in ids


def test_exclude_only_no_have_set(client, household, items):
    """Exclude-only filter (empty include_ids) hides excluded recipes, shows rest."""
    egg, bacon = items["egg"], items["bacon"]
    recipe_with_bacon = _make_recipe(household.id, "Bacon Thing", required=[egg, bacon])
    recipe_no_bacon = _make_recipe(household.id, "Egg Only", required=[egg])

    results = Recipe.filter_by_items(
        household.id,
        include_ids=[],
        exclude_ids=[bacon.id],
        tags=[],
        max_missing=0,
    )
    ids = [r.id for r, _ in results]
    assert recipe_with_bacon.id not in ids
    assert recipe_no_bacon.id in ids
    mc = next(mc for r, mc in results if r.id == recipe_no_bacon.id)
    assert mc == 0


def test_optional_items_not_counted_as_missing(client, household, items):
    """Optional items do not count toward missing_count."""
    egg, oil = items["egg"], items["oil"]
    # egg is required, oil is optional
    recipe = _make_recipe(household.id, "Simple Egg", required=[egg], optional=[oil])

    # Have egg but not oil — oil is optional so missing_count == 0
    results = Recipe.filter_by_items(
        household.id,
        include_ids=[egg.id],
        exclude_ids=[],
        tags=[],
        max_missing=0,
    )
    ids = [r.id for r, _ in results]
    assert recipe.id in ids
    mc = next(mc for r, mc in results if r.id == recipe.id)
    assert mc == 0


def test_exclude_hides_recipe_with_required_item(client, household, items):
    """A recipe is hidden when it contains an excluded required item."""
    egg, bacon = items["egg"], items["bacon"]
    recipe = _make_recipe(household.id, "Bacon And Eggs", required=[egg, bacon])

    results = Recipe.filter_by_items(
        household.id,
        include_ids=[egg.id, bacon.id],
        exclude_ids=[bacon.id],
        tags=[],
        max_missing=0,
    )
    ids = [r.id for r, _ in results]
    assert recipe.id not in ids


def test_exclude_hides_recipe_with_optional_item(client, household, items):
    """A recipe is hidden when it contains an excluded optional item."""
    egg, bacon = items["egg"], items["bacon"]
    # bacon is optional but still excluded
    recipe = _make_recipe(household.id, "Egg With Optional Bacon", required=[egg], optional=[bacon])

    results = Recipe.filter_by_items(
        household.id,
        include_ids=[egg.id],
        exclude_ids=[bacon.id],
        tags=[],
        max_missing=0,
    )
    ids = [r.id for r, _ in results]
    assert recipe.id not in ids


def test_tag_filter_composes_with_ingredient_filter(client, household, items):
    """Tag filter AND ingredient filter must both be satisfied."""
    egg, apple = items["egg"], items["apple"]

    # Add a tag to the household
    tag = Tag(name="breakfast", household_id=household.id)
    db.session.add(tag)
    db.session.flush()

    recipe_tagged = _make_recipe(household.id, "Egg Breakfast", required=[egg])
    recipe_no_tag = _make_recipe(household.id, "Plain Egg", required=[egg])

    db.session.add(RecipeTags(recipe_id=recipe_tagged.id, tag_id=tag.id))
    db.session.commit()

    results = Recipe.filter_by_items(
        household.id,
        include_ids=[egg.id, apple.id],
        exclude_ids=[],
        tags=["breakfast"],
        max_missing=0,
    )
    ids = [r.id for r, _ in results]
    assert recipe_tagged.id in ids
    assert recipe_no_tag.id not in ids


def test_sort_order_cookable_first(client, household, items):
    """Results are ordered: cookable (missing=0) before missing, then by name."""
    egg, oil, apple = items["egg"], items["oil"], items["apple"]

    r_missing = _make_recipe(household.id, "Apple Cake", required=[egg, apple])
    r_cookable = _make_recipe(household.id, "Fried Egg", required=[egg, oil])

    # Have egg + oil but not apple
    results = Recipe.filter_by_items(
        household.id,
        include_ids=[egg.id, oil.id],
        exclude_ids=[],
        tags=[],
        max_missing=1,
    )
    ids = [r.id for r, _ in results]
    assert ids.index(r_cookable.id) < ids.index(r_missing.id)


def test_no_items_recipe_always_cookable(client, household, items):
    """A recipe with no required items has missing_count==0 regardless of have-set."""
    recipe = _make_recipe(household.id, "Just Water", required=[])

    results = Recipe.filter_by_items(
        household.id,
        include_ids=[],
        exclude_ids=[],
        tags=[],
        max_missing=0,
    )
    ids = [r.id for r, _ in results]
    assert recipe.id in ids
    mc = next(mc for r, mc in results if r.id == recipe.id)
    assert mc == 0
