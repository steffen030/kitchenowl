import 'package:flutter_test/flutter_test.dart';
import 'package:kitchenowl/cubits/recipe_list_cubit.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/item.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/models/tag.dart';

// ---------------------------------------------------------------------------
// Test data
// ---------------------------------------------------------------------------

const household = Household(id: 1, name: 'Test');

const egg = Item(id: 10, name: 'Egg');
const oil = Item(id: 11, name: 'Oil');
const apple = Item(id: 12, name: 'Apple');
const bacon = Item(id: 13, name: 'Bacon');

const tagBreakfast = Tag(id: 1, name: 'breakfast');
const tagDinner = Tag(id: 2, name: 'dinner');

const eggRequired = RecipeItem(id: 10, name: 'Egg', optional: false);
const oilRequired = RecipeItem(id: 11, name: 'Oil', optional: false);
const appleRequired = RecipeItem(id: 12, name: 'Apple', optional: false);
const baconRequired = RecipeItem(id: 13, name: 'Bacon', optional: false);
const oilOptional = RecipeItem(id: 11, name: 'Oil', optional: true);

final recipeScrambled = Recipe(
  id: 1,
  name: 'Scrambled Eggs',
  items: const [eggRequired, oilRequired],
  tags: {tagBreakfast},
);

const recipeApple = Recipe(
  id: 2,
  name: 'Apple Cake',
  items: [appleRequired],
);

const recipeBacon = Recipe(
  id: 3,
  name: 'Bacon Sandwich',
  items: [baconRequired],
);

const recipeNoItems = Recipe(
  id: 4,
  name: 'Plain Water',
  items: [],
);

const recipeOptionalOil = Recipe(
  id: 5,
  name: 'Egg Dish',
  items: [eggRequired, oilOptional],
);

RecipeListCubit _cubit(List<Recipe> recipes, [Set<Tag> tags = const {}]) =>
    RecipeListCubit.forTesting(household, recipes, tags);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('RecipeListCubit ingredient filter', () {
    test('initial state is ListRecipeListState with all recipes', () {
      final cubit = _cubit([recipeScrambled, recipeApple]);
      expect(cubit.state, isA<ListRecipeListState>());
      expect(
        (cubit.state as ListRecipeListState).recipes,
        containsAll([recipeScrambled, recipeApple]),
      );
    });

    test('setIncludeItem transitions to FilteredListRecipeListState', () {
      final cubit = _cubit([recipeScrambled, recipeApple]);
      cubit.setIncludeItem(egg, true);
      expect(cubit.state, isA<FilteredListRecipeListState>());
    });

    test('cookable recipe appears with missingCount 0', () {
      final cubit = _cubit([recipeScrambled]);
      cubit.setIncludeItem(egg, true);
      cubit.setIncludeItem(oil, true);
      final filtered = (cubit.state as FilteredListRecipeListState).recipes;
      expect(filtered.length, 1);
      expect(filtered.first.missingCount, 0);
    });

    test('missing_count equals number of required items not in include set', () {
      final cubit = _cubit([recipeScrambled]);
      cubit.setIncludeItem(egg, true);
      // oil is missing → missingCount should be 1 but max_missing=0 → excluded
      expect((cubit.state as FilteredListRecipeListState).recipes, isEmpty);

      cubit.setMaxMissing(1);
      final filtered = (cubit.state as FilteredListRecipeListState).recipes;
      expect(filtered.length, 1);
      expect(filtered.first.missingCount, 1);
    });

    test('optional items do not count toward missingCount', () {
      final cubit = _cubit([recipeOptionalOil]);
      cubit.setIncludeItem(egg, true);
      // oil is optional → missingCount = 0
      final filtered = (cubit.state as FilteredListRecipeListState).recipes;
      expect(filtered.length, 1);
      expect(filtered.first.missingCount, 0);
    });

    test('setExcludeItem hides recipe with excluded required item', () {
      final cubit = _cubit([recipeScrambled, recipeApple]);
      cubit.setIncludeItem(egg, true);
      cubit.setIncludeItem(oil, true);
      cubit.setIncludeItem(apple, true);
      cubit.setExcludeItem(bacon, true);
      // scrambled contains egg+oil (cookable), apple cake has apple (cookable)
      // bacon is excluded but neither recipe has bacon
      final ids = (cubit.state as FilteredListRecipeListState)
          .recipes
          .map((r) => r.id)
          .toList();
      expect(ids, containsAll([recipeScrambled.id, recipeApple.id]));

      // Now exclude egg → scrambled is hidden
      cubit.setExcludeItem(egg, true);
      final ids2 = (cubit.state as FilteredListRecipeListState)
          .recipes
          .map((r) => r.id)
          .toList();
      expect(ids2, isNot(contains(recipeScrambled.id)));
    });

    test('setExcludeItem hides recipe with excluded optional item', () {
      final cubit = _cubit([recipeOptionalOil]);
      cubit.setIncludeItem(egg, true);
      cubit.setExcludeItem(oil, true); // oil is optional in recipeOptionalOil
      final filtered = (cubit.state as FilteredListRecipeListState).recipes;
      expect(filtered, isEmpty);
    });

    test('tag filter and ingredient filter compose (AND)', () {
      final cubit =
          _cubit([recipeScrambled, recipeApple], {tagBreakfast, tagDinner});
      cubit.setIncludeItem(egg, true);
      cubit.setIncludeItem(oil, true);
      cubit.tagSelected(tagBreakfast, true);
      final ids = (cubit.state as FilteredListRecipeListState)
          .recipes
          .map((r) => r.id)
          .toList();
      // recipeScrambled has breakfast tag AND egg+oil → included
      expect(ids, contains(recipeScrambled.id));
      // recipeApple has no breakfast tag → excluded
      expect(ids, isNot(contains(recipeApple.id)));
    });

    test('recipe with no required items has missingCount 0', () {
      final cubit = _cubit([recipeNoItems]);
      cubit.setIncludeItem(egg, true);
      final filtered = (cubit.state as FilteredListRecipeListState).recipes;
      expect(filtered.length, 1);
      expect(filtered.first.missingCount, 0);
    });

    test('sort order: cookable first, then by missingCount, then by name', () {
      final cubit = _cubit([recipeScrambled, recipeApple, recipeNoItems]);
      // Have egg + oil but not apple
      cubit.setIncludeItem(egg, true);
      cubit.setIncludeItem(oil, true);
      cubit.setMaxMissing(1);
      final recipes = (cubit.state as FilteredListRecipeListState).recipes;
      // Cookable: recipeNoItems (mc=0), recipeScrambled (mc=0)
      // Missing 1: recipeApple (mc=1)
      final scrambledIdx =
          recipes.indexWhere((r) => r.id == recipeScrambled.id);
      final appleIdx = recipes.indexWhere((r) => r.id == recipeApple.id);
      final waterIdx = recipes.indexWhere((r) => r.id == recipeNoItems.id);
      expect(scrambledIdx, lessThan(appleIdx));
      expect(waterIdx, lessThan(appleIdx));
    });

    test(
        'clearing all ingredient filters returns to ListRecipeListState', () {
      final cubit = _cubit([recipeScrambled]);
      cubit.setIncludeItem(egg, true);
      expect(cubit.state, isA<FilteredListRecipeListState>());
      cubit.setIncludeItem(egg, false);
      expect(cubit.state, isA<ListRecipeListState>());
      expect(cubit.state, isNot(isA<FilteredListRecipeListState>()));
    });

    test('removing tag clears to ListRecipeListState when no other filters', () {
      final cubit = _cubit([recipeScrambled], {tagBreakfast});
      cubit.tagSelected(tagBreakfast, true);
      expect(cubit.state, isA<FilteredListRecipeListState>());
      cubit.tagSelected(tagBreakfast, false);
      expect(cubit.state, isNot(isA<FilteredListRecipeListState>()));
    });

    test(
        'removing tag keeps FilteredListRecipeListState when ingredient filter remains',
        () {
      final cubit = _cubit([recipeScrambled], {tagBreakfast});
      cubit.setIncludeItem(egg, true);
      cubit.tagSelected(tagBreakfast, true);
      cubit.tagSelected(tagBreakfast, false);
      // ingredient filter still active
      expect(cubit.state, isA<FilteredListRecipeListState>());
    });

    test('setExcludeItem alone activates FilteredListRecipeListState', () {
      final cubit = _cubit([recipeScrambled, recipeBacon]);
      cubit.setExcludeItem(bacon, true);
      expect(cubit.state, isA<FilteredListRecipeListState>());
      final ids = (cubit.state as FilteredListRecipeListState)
          .recipes
          .map((r) => r.id)
          .toList();
      expect(ids, isNot(contains(recipeBacon.id)));
      expect(ids, contains(recipeScrambled.id));
    });
  });
}
