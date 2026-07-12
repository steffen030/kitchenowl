import 'package:flutter/material.dart';
import 'package:kitchenowl/cubits/recipe_list_cubit.dart';
import 'package:kitchenowl/kitchenowl.dart';
import 'package:kitchenowl/models/household.dart';
import 'package:kitchenowl/models/item.dart';
import 'package:kitchenowl/pages/item_search_page.dart';

/// Bottom sheet for configuring the ingredient include/exclude filter.
class IngredientFilterSheet extends StatefulWidget {
  final Household household;
  final FilteredListRecipeListState? currentFilter;

  const IngredientFilterSheet({
    super.key,
    required this.household,
    this.currentFilter,
  });

  @override
  State<IngredientFilterSheet> createState() => _IngredientFilterSheetState();
}

class _IngredientFilterSheetState extends State<IngredientFilterSheet> {
  late Set<Item> _includeItems;
  late Set<Item> _excludeItems;
  late int _maxMissing;

  @override
  void initState() {
    super.initState();
    _includeItems = Set<Item>.from(widget.currentFilter?.includeItems ?? {});
    _excludeItems = Set<Item>.from(widget.currentFilter?.excludeItems ?? {});
    _maxMissing = widget.currentFilter?.maxMissing ?? 0;
  }

  Future<void> _pickItems(
    BuildContext context,
    String title,
    Set<Item> current,
    void Function(Set<Item>) onResult,
  ) async {
    final result = await Navigator.of(context, rootNavigator: true)
        .push<List<Item>>(MaterialPageRoute(
      builder: (context) => ItemSearchPage(
        household: widget.household,
        title: title,
        selectedItems: current.toList(),
      ),
    ));
    if (result != null) {
      onResult(Set<Item>.from(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.filterByIngredients,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            // Include section
            Text(l10n.ingredientsIHave,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _ItemChipList(
              items: _includeItems,
              onRemove: (item) => setState(
                () => _includeItems.removeWhere((e) => e.id == item.id),
              ),
              onAdd: () => _pickItems(
                context,
                l10n.ingredientsIHave,
                _includeItems,
                (result) => setState(() => _includeItems = result),
              ),
            ),
            const SizedBox(height: 16),
            // Exclude section
            Text(l10n.excludeIngredients,
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _ItemChipList(
              items: _excludeItems,
              onRemove: (item) => setState(
                () => _excludeItems.removeWhere((e) => e.id == item.id),
              ),
              onAdd: () => _pickItems(
                context,
                l10n.excludeIngredients,
                _excludeItems,
                (result) => setState(() => _excludeItems = result),
              ),
            ),
            const SizedBox(height: 16),
            // max_missing stepper (only shown when include items are selected)
            if (_includeItems.isNotEmpty) ...[
              Text(
                l10n.showRecipesMissingUpTo(_maxMissing),
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_rounded),
                    onPressed: _maxMissing > 0
                        ? () => setState(() => _maxMissing--)
                        : null,
                  ),
                  Text(
                    '$_maxMissing',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_rounded),
                    onPressed: _maxMissing < 10
                        ? () => setState(() => _maxMissing++)
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            // Action buttons
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(
                    const _FilterResult(
                      includeItems: {},
                      excludeItems: {},
                      maxMissing: 0,
                      cleared: true,
                    ),
                  ),
                  child: Text(AppLocalizations.of(context)!.clear),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(
                    _FilterResult(
                      includeItems: _includeItems,
                      excludeItems: _excludeItems,
                      maxMissing: _maxMissing,
                    ),
                  ),
                  child: Text(AppLocalizations.of(context)!.confirm),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterResult {
  final Set<Item> includeItems;
  final Set<Item> excludeItems;
  final int maxMissing;
  final bool cleared;

  const _FilterResult({
    required this.includeItems,
    required this.excludeItems,
    required this.maxMissing,
    this.cleared = false,
  });
}

class _ItemChipList extends StatelessWidget {
  final Set<Item> items;
  final void Function(Item) onRemove;
  final VoidCallback onAdd;

  const _ItemChipList({
    required this.items,
    required this.onRemove,
    required this.onAdd,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        ...items.map((item) => Chip(
              label: Text(item.name),
              deleteIcon: const Icon(Icons.close_rounded, size: 16),
              onDeleted: () => onRemove(item),
            )),
        ActionChip(
          avatar: const Icon(Icons.add_rounded, size: 16),
          label: Text(AppLocalizations.of(context)!.add),
          onPressed: onAdd,
        ),
      ],
    );
  }
}

/// Shows the ingredient filter sheet and applies changes to the cubit.
Future<void> showIngredientFilterSheet(
  BuildContext context,
  RecipeListCubit cubit,
  Household household,
) async {
  final current = cubit.state is FilteredListRecipeListState
      ? cubit.state as FilteredListRecipeListState
      : null;

  final result = await showModalBottomSheet<_FilterResult>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => IngredientFilterSheet(
      household: household,
      currentFilter: current,
    ),
  );

  if (result == null) return;

  cubit.setIngredientFilter(
    includeItems: result.cleared ? const {} : result.includeItems,
    excludeItems: result.cleared ? const {} : result.excludeItems,
    maxMissing: result.cleared ? 0 : result.maxMissing,
  );
}
