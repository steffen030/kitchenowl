import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/item.dart';
import 'package:kitchenowl/models/recipe.dart';
import 'package:kitchenowl/models/tag.dart';
import 'package:kitchenowl/services/api/api_service.dart';
import 'package:kitchenowl/services/recipe_sync_service.dart';
import 'package:kitchenowl/services/storage/storage.dart';
import 'package:kitchenowl/services/transaction_handler.dart';
import 'package:kitchenowl/services/transactions/recipe.dart';
import 'package:kitchenowl/services/transactions/tag.dart';

class RecipeListCubit extends Cubit<RecipeListState> {
  final Household household;
  List<Recipe> recipeList = [];
  Future<void>? _refreshThread;
  String? _refreshCurrentQuery;

  static const int _perPage = 50;

  RecipeListCubit(this.household) : super(const LoadingRecipeListState()) {
    PreferenceStorage.getInstance().readBool(key: 'recipeListView').then((i) {
      if (i != null && state.listView != i) {
        toggleView(false);
      }
    });
    _initialLoad();
  }

  RecipeListCubit.forTesting(
    this.household,
    List<Recipe> initialRecipes,
    Set<Tag> initialTags,
  ) : super(ListRecipeListState(recipes: initialRecipes, tags: initialTags)) {
    recipeList = initialRecipes;
  }

  String get query => (state is SearchRecipeListState)
      ? (state as SearchRecipeListState).query
      : "";

  Future<void> search(String query) {
    return refresh(query);
  }

  FilteredListRecipeListState _getFilteredState() {
    if (state is FilteredListRecipeListState) {
      return state as FilteredListRecipeListState;
    }
    final s = state as ListRecipeListState;
    return FilteredListRecipeListState(
      allRecipes: s.recipes,
      recipes: s.recipes,
      tags: s.tags,
      listView: state.listView,
    );
  }

  void _emitFilteredOrClear(
    FilteredListRecipeListState current, {
    Set<Tag>? selectedTags,
    Set<Item>? includeItems,
    Set<Item>? excludeItems,
    int? maxMissing,
  }) {
    final newTags = selectedTags ?? current.selectedTags;
    final newInclude = includeItems ?? current.includeItems;
    final newExclude = excludeItems ?? current.excludeItems;
    final newMax = maxMissing ?? current.maxMissing;

    if (newTags.isEmpty && newInclude.isEmpty && newExclude.isEmpty) {
      emit(ListRecipeListState(
        recipes: current.allRecipes,
        tags: current.tags,
        listView: state.listView,
      ));
      return;
    }

    emit(current.copyWith(
      selectedTags: newTags,
      includeItems: newInclude,
      excludeItems: newExclude,
      maxMissing: newMax,
      recipes: _applyAllFilters(
        current.allRecipes,
        newTags,
        newInclude,
        newExclude,
        newMax,
      ),
    ));
  }

  void tagSelected(Tag tag, bool selected) {
    if (state is! ListRecipeListState) return;
    final current = _getFilteredState();
    final selectedTags = Set<Tag>.from(current.selectedTags);
    if (selected) {
      selectedTags.add(tag);
    } else {
      selectedTags.removeWhere((e) => e.id == tag.id);
    }
    _emitFilteredOrClear(current, selectedTags: selectedTags);
  }

  void setIncludeItem(Item item, bool add) {
    if (state is! ListRecipeListState) return;
    final current = _getFilteredState();
    final includeItems = Set<Item>.from(current.includeItems);
    if (add) {
      includeItems.add(item);
    } else {
      includeItems.removeWhere((e) => e.id == item.id);
    }
    _emitFilteredOrClear(current, includeItems: includeItems);
  }

  void setExcludeItem(Item item, bool add) {
    if (state is! ListRecipeListState) return;
    final current = _getFilteredState();
    final excludeItems = Set<Item>.from(current.excludeItems);
    if (add) {
      excludeItems.add(item);
    } else {
      excludeItems.removeWhere((e) => e.id == item.id);
    }
    _emitFilteredOrClear(current, excludeItems: excludeItems);
  }

  void setMaxMissing(int value) {
    if (state is! ListRecipeListState) return;
    final current = _getFilteredState();
    _emitFilteredOrClear(current, maxMissing: value);
  }

  void setIngredientFilter({
    required Set<Item> includeItems,
    required Set<Item> excludeItems,
    required int maxMissing,
  }) {
    if (state is! ListRecipeListState) return;
    final current = _getFilteredState();
    _emitFilteredOrClear(
      current,
      includeItems: includeItems,
      excludeItems: excludeItems,
      maxMissing: maxMissing,
    );
  }

  Future<void> refresh([String? query]) {
    final state = this.state;
    if (state is SearchRecipeListState) {
      query = query ?? state.query;
    }
    if (_refreshThread == null || query != _refreshCurrentQuery) {
      _refreshCurrentQuery = query;
      _refreshThread = _refresh(query);
    }

    return _refreshThread!;
  }

  Future<void> loadMore() async {
    final currentState = state;
    if (currentState is! ListRecipeListState) return;
    if (!currentState.hasMore) return;
    if (currentState.isLoadingMore) return;
    // search/filter states don't paginate
    if (currentState is SearchRecipeListState) return;
    if (currentState is FilteredListRecipeListState) return;

    final nextPage = currentState.currentPage + 1;
    emit(currentState.copyWith(isLoadingMore: true));

    try {
      final result = await ApiService.getInstance().getRecipesPaginated(
        household,
        page: nextPage,
        perPage: _perPage,
      );
      if (result == null) {
        if (!isClosed && state is ListRecipeListState) {
          emit((state as ListRecipeListState).copyWith(isLoadingMore: false));
        }
        return;
      }

      final merged = List<Recipe>.from(recipeList)..addAll(result.items);
      recipeList = merged;

      final tags = await TransactionHandler.getInstance().runTransaction(
        TransactionTagGetAll(household: household),
        forceOffline: true,
      );

      if (!isClosed) {
        emit(ListRecipeListState(
          recipes: merged,
          tags: tags,
          listView: state.listView,
          hasMore: result.hasMore,
          currentPage: nextPage,
        ));
      }
    } catch (_) {
      // restore previous state without loading indicator
      if (!isClosed && state is ListRecipeListState) {
        emit((state as ListRecipeListState).copyWith(isLoadingMore: false));
      }
    }
  }

  Future<void> _initialLoad() async {
    // On web skip local cache — rely on network only
    if (kIsWeb) return;

    final tags = TransactionHandler.getInstance().runTransaction(
      TransactionTagGetAll(household: household),
      forceOffline: true,
    );
    recipeList = await TransactionHandler.getInstance().runTransaction(
      TransactionRecipeGetRecipes(household: household),
      forceOffline: true,
    );

    if (state is LoadingRecipeListState && recipeList.isNotEmpty) {
      emit(ListRecipeListState(
        recipes: recipeList,
        tags: await tags,
        listView: state.listView,
      ));
    }
  }

  Future<void> _refresh([String? query, bool runOffline = false]) async {
    late ListRecipeListState _state;
    if (state is ListRecipeListState &&
        state is! SearchRecipeListState &&
        state is! FilteredListRecipeListState &&
        (state as ListRecipeListState).recipes.isEmpty) {
      emit(LoadingRecipeListState(listView: state.listView));
    }

    if (query != null && query.isNotEmpty) {
      final tags = TransactionHandler.getInstance()
          .runTransaction(TransactionTagGetAll(household: household));
      final recipes = TransactionHandler.getInstance()
          .runTransaction(TransactionRecipeSearchRecipes(
        household: household,
        query: query,
      ));

      _state = SearchRecipeListState(
        query: query,
        recipes: await recipes,
        tags: await tags,
        listView: state.listView,
      );
    } else {
      if (!runOffline && state is SearchRecipeListState) _refresh(query, true);

      try {
        final tags = TransactionHandler.getInstance().runTransaction(
          TransactionTagGetAll(household: household),
          forceOffline: runOffline,
        );

        // Read filter state before any awaits so we don't observe a mid-refresh state.
        Set<Tag> tagFilter = const {};
        Set<Item> includeItems = const {};
        Set<Item> excludeItems = const {};
        int maxMissing = 0;
        if (state is FilteredListRecipeListState && query == null) {
          final s = state as FilteredListRecipeListState;
          tagFilter = s.selectedTags;
          includeItems = s.includeItems;
          excludeItems = s.excludeItems;
          maxMissing = s.maxMissing;
        }

        final hasIngredientFilter =
            includeItems.isNotEmpty || excludeItems.isNotEmpty;
        final hasFilter = tagFilter.isNotEmpty || hasIngredientFilter;

        if (runOffline || hasIngredientFilter) {
          // Ingredient filtering requires full recipe details (items list), so
          // we load the full recipe list from cache/network rather than slim pages.
          recipeList = await TransactionHandler.getInstance().runTransaction(
            TransactionRecipeGetRecipes(household: household),
            forceOffline: runOffline,
          );
          final displayRecipes = _applyAllFilters(
            recipeList,
            tagFilter,
            includeItems,
            excludeItems,
            maxMissing,
          );
          _state = hasFilter
              ? FilteredListRecipeListState(
                  recipes: displayRecipes,
                  tags: await tags,
                  selectedTags: tagFilter,
                  includeItems: includeItems,
                  excludeItems: excludeItems,
                  maxMissing: maxMissing,
                  allRecipes: recipeList,
                  listView: state.listView,
                )
              : ListRecipeListState(
                  recipes: recipeList,
                  tags: await tags,
                  listView: state.listView,
                );
        } else {
          // Load first page from network using slim paginated endpoint.
          final result = await ApiService.getInstance().getRecipesPaginated(
            household,
            page: 0,
            perPage: _perPage,
          );
          if (result == null) {
            if (query == _refreshCurrentQuery && !isClosed) {
              // Only show error page when there's nothing cached to display
              if (recipeList.isEmpty) {
                emit(ErrorRecipeListState(listView: state.listView));
              }
              _refreshThread = null;
            }
            return;
          }
          recipeList = result.items;
          // Do NOT write slim list to the offline cache — the background sync
          // service writes full-detail recipes. Only mobile uses offline cache.
          if (!kIsWeb) {
            RecipeSyncService.getInstance().sync(household);
          }

          _state = tagFilter.isNotEmpty
              ? FilteredListRecipeListState(
                  recipes: _getFilteredRecipesCopy(recipeList, tagFilter),
                  tags: await tags,
                  selectedTags: tagFilter,
                  allRecipes: recipeList,
                  listView: state.listView,
                  hasMore: result.hasMore,
                  currentPage: 0,
                )
              : ListRecipeListState(
                  recipes: recipeList,
                  tags: await tags,
                  listView: state.listView,
                  hasMore: result.hasMore,
                  currentPage: 0,
                );
        }
      } catch (_) {
        if (query == _refreshCurrentQuery && !isClosed) {
          // Only replace current list with error state when there's nothing to show
          if (recipeList.isEmpty) {
            emit(ErrorRecipeListState(listView: state.listView));
          }
          _refreshThread = null;
        }
        return;
      }
    }
    if (query == _refreshCurrentQuery && !isClosed) {
      emit(_state);
      _refreshThread = null;
    }
  }

  List<Recipe> _getFilteredRecipesCopy(
    List<Recipe> allRecipes,
    Set<Tag> filter,
  ) =>
      List<Recipe>.from(
        allRecipes.where((e) => e.tags.containsAll(filter)),
      );

  List<Recipe> _applyAllFilters(
    List<Recipe> allRecipes,
    Set<Tag> tags,
    Set<Item> includeItems,
    Set<Item> excludeItems,
    int maxMissing,
  ) {
    if (includeItems.isEmpty && excludeItems.isEmpty) {
      return _getFilteredRecipesCopy(allRecipes, tags);
    }

    final includeIds =
        includeItems.map((e) => e.id).whereType<int>().toSet();
    final excludeIds =
        excludeItems.map((e) => e.id).whereType<int>().toSet();

    final filtered = <(Recipe recipe, int missingCount)>[];

    for (final recipe in allRecipes) {
      if (tags.isNotEmpty && !recipe.tags.containsAll(tags)) continue;

      if (excludeIds.isNotEmpty &&
          recipe.items.any((ri) => ri.id != null && excludeIds.contains(ri.id))) {
        continue;
      }

      final missingCount = includeIds.isEmpty
          ? 0
          : recipe.mandatoryItems
              .where((ri) => ri.id == null || !includeIds.contains(ri.id))
              .length;

      if (missingCount > maxMissing) continue;

      filtered.add((recipe, missingCount));
    }

    filtered.sort((a, b) {
      final aCookable = a.$2 == 0 ? 0 : 1;
      final bCookable = b.$2 == 0 ? 0 : 1;
      if (aCookable != bCookable) return aCookable.compareTo(bCookable);
      if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
      return a.$1.name.compareTo(b.$1.name);
    });

    return filtered
        .map((e) => e.$1.copyWith(missingCount: e.$2))
        .toList();
  }

  void toggleView([bool savePreference = true]) {
    if (savePreference) {
      PreferenceStorage.getInstance()
          .writeBool(key: 'recipeListView', value: !state.listView);
    }
    emit(state.copyWith(listView: !state.listView));
  }
}

abstract class RecipeListState extends Equatable {
  final bool listView;
  const RecipeListState({this.listView = true});

  @override
  List<Object?> get props => [listView];

  RecipeListState copyWith({bool? listView});
}

class LoadingRecipeListState extends RecipeListState {
  const LoadingRecipeListState({super.listView});

  @override
  RecipeListState copyWith({bool? listView}) {
    return LoadingRecipeListState(listView: listView ?? this.listView);
  }
}

class ErrorRecipeListState extends RecipeListState {
  const ErrorRecipeListState({super.listView});

  @override
  RecipeListState copyWith({bool? listView}) {
    return ErrorRecipeListState(listView: listView ?? this.listView);
  }
}

class ListRecipeListState extends RecipeListState {
  final List<Recipe> recipes;
  final Set<Tag> tags;
  final bool hasMore;
  final bool isLoadingMore;
  final int currentPage;

  const ListRecipeListState({
    this.recipes = const [],
    this.tags = const {},
    super.listView,
    this.hasMore = false,
    this.isLoadingMore = false,
    this.currentPage = 0,
  });

  @override
  List<Object?> get props =>
      super.props + <Object?>[tags, hasMore, isLoadingMore, currentPage] + recipes;

  @override
  ListRecipeListState copyWith({
    bool? listView,
    List<Recipe>? recipes,
    Set<Tag>? tags,
    bool? hasMore,
    bool? isLoadingMore,
    int? currentPage,
  }) {
    return ListRecipeListState(
      listView: listView ?? this.listView,
      recipes: recipes ?? this.recipes,
      tags: tags ?? this.tags,
      hasMore: hasMore ?? this.hasMore,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      currentPage: currentPage ?? this.currentPage,
    );
  }
}

class FilteredListRecipeListState extends ListRecipeListState {
  final Set<Tag> selectedTags;
  final Set<Item> includeItems;
  final Set<Item> excludeItems;
  final int maxMissing;
  final List<Recipe> allRecipes;

  const FilteredListRecipeListState({
    this.selectedTags = const {},
    this.includeItems = const {},
    this.excludeItems = const {},
    this.maxMissing = 0,
    this.allRecipes = const [],
    super.recipes = const [],
    super.tags = const {},
    super.listView,
    super.hasMore = false,
    super.isLoadingMore = false,
    super.currentPage = 0,
  });

  bool get hasIngredientFilter =>
      includeItems.isNotEmpty || excludeItems.isNotEmpty;

  factory FilteredListRecipeListState.fromState(
    ListRecipeListState state,
    Tag selectedTag,
  ) =>
      FilteredListRecipeListState(
        recipes: List<Recipe>.from(
          state.recipes.where((e) => e.tags.contains(selectedTag)),
        ),
        allRecipes: state.recipes,
        tags: state.tags,
        selectedTags: {selectedTag},
        listView: state.listView,
        hasMore: state.hasMore,
        currentPage: state.currentPage,
      );

  @override
  FilteredListRecipeListState copyWith({
    bool? listView,
    List<Recipe>? recipes,
    Set<Tag>? tags,
    Set<Tag>? selectedTags,
    Set<Item>? includeItems,
    Set<Item>? excludeItems,
    int? maxMissing,
    bool? hasMore,
    bool? isLoadingMore,
    int? currentPage,
  }) =>
      FilteredListRecipeListState(
        listView: listView ?? this.listView,
        recipes: recipes ?? this.recipes,
        tags: tags ?? this.tags,
        selectedTags: selectedTags ?? this.selectedTags,
        includeItems: includeItems ?? this.includeItems,
        excludeItems: excludeItems ?? this.excludeItems,
        maxMissing: maxMissing ?? this.maxMissing,
        allRecipes: allRecipes,
        hasMore: hasMore ?? this.hasMore,
        isLoadingMore: isLoadingMore ?? this.isLoadingMore,
        currentPage: currentPage ?? this.currentPage,
      );

  @override
  List<Object?> get props =>
      super.props + [selectedTags] + includeItems.toList() + excludeItems.toList() + [maxMissing];
}

class SearchRecipeListState extends ListRecipeListState {
  final String query;

  const SearchRecipeListState({
    required this.query,
    super.recipes = const [],
    super.tags = const {},
    super.listView,
  });

  @override
  List<Object?> get props => super.props + [query];

  @override
  SearchRecipeListState copyWith({
    bool? listView,
    List<Recipe>? recipes,
    Set<Tag>? tags,
    bool? hasMore,
    bool? isLoadingMore,
    int? currentPage,
    String? query,
  }) {
    return SearchRecipeListState(
      listView: listView ?? this.listView,
      query: query ?? this.query,
      recipes: recipes ?? this.recipes,
      tags: tags ?? this.tags,
    );
  }
}
