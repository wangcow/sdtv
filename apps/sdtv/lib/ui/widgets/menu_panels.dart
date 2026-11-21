import 'package:flutter/material.dart';

/// One row of the ☰ menu or the Settings page.
class MenuEntry {
  const MenuEntry(
    this.id,
    this.icon,
    this.title, {
    this.subtitle,
    this.section,
    this.danger = false,
  });

  final String id;
  final IconData icon;
  final String title;

  /// Current value / detail under the title (Settings).
  final String? subtitle;

  /// Section heading shown above the first row of a section (Settings).
  final String? section;

  /// Destructive (Sign out): red when focused.
  final bool danger;
}

/// ☰ menu: a slim panel on the left edge, TiviMate-style. No animations
/// (pad-driven, and it opens over a static guide).
class SideMenu extends StatelessWidget {
  const SideMenu({
    super.key,
    required this.entries,
    required this.selected,
    required this.accountLine,
    required this.onTap,
    required this.onDismiss,
  });

  final List<MenuEntry> entries;
  final int selected;

  /// e.g. `mock_user · DEMO`
  final String accountLine;
  final ValueChanged<int> onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onDismiss,
            child: const ColoredBox(color: Color(0x8C000000)),
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 340,
          child: Material(
            color: scheme.surfaceContainerLow,
            elevation: 16,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'sdtv',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(
                          Icons.account_circle_outlined,
                          size: 18,
                          color: scheme.outline,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            accountLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: scheme.onSurface.withValues(alpha: 0.7),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    for (var i = 0; i < entries.length; i++)
                      _Row(
                        entry: entries[i],
                        focused: i == selected,
                        onTap: () => onTap(i),
                      ),
                    const Spacer(),
                    Text(
                      'A select  ·  B close',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Full-screen Settings, TiviMate-style: grouped rows with their current
/// value underneath. Sub-panels (playlists, categories, about) open on top.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.entries,
    required this.selected,
    required this.onTap,
  });

  final List<MenuEntry> entries;
  final int selected;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 14),
            color: scheme.surfaceContainerLow,
            child: Row(
              children: [
                Icon(Icons.settings_outlined, color: scheme.primary, size: 28),
                const SizedBox(width: 12),
                Text(
                  'Settings',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
                  children: [
                    for (var i = 0; i < entries.length; i++) ...[
                      if (entries[i].section != null)
                        Padding(
                          padding: EdgeInsets.fromLTRB(
                            4,
                            i == 0 ? 8 : 22,
                            4,
                            8,
                          ),
                          child: Text(
                            entries[i].section!.toUpperCase(),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.outline,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                            ),
                          ),
                        ),
                      _Row(
                        entry: entries[i],
                        focused: i == selected,
                        onTap: () => onTap(i),
                        tall: true,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            color: scheme.surfaceContainerLow,
            alignment: Alignment.centerLeft,
            child: Text(
              '↑↓ move  ·  A open  ·  B back',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.entry,
    required this.focused,
    required this.onTap,
    this.tall = false,
  });

  final MenuEntry entry;
  final bool focused;
  final VoidCallback onTap;
  final bool tall;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final danger = entry.danger;
    final bg = focused
        ? (danger ? scheme.error : scheme.primary)
        : (tall ? scheme.surfaceContainerHigh : Colors.transparent);
    final fg = focused
        ? (danger ? scheme.onError : scheme.onPrimary)
        : (danger ? scheme.error : scheme.onSurface);
    final sub = entry.subtitle;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: tall ? 14 : 12,
          ),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(entry.icon, color: fg, size: 24),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      entry.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: fg,
                        fontWeight: focused ? FontWeight.w800 : FontWeight.w600,
                      ),
                    ),
                    if (sub != null && sub.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: fg.withValues(alpha: focused ? 0.85 : 0.6),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (tall)
                Icon(
                  Icons.chevron_right_rounded,
                  color: fg.withValues(alpha: 0.6),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Settings → Manage categories: full screen like Settings. X hides or
/// shows the focused category; A picks it up so ↑↓ move it, A / B drop it.
class ManageCategoriesPage extends StatelessWidget {
  const ManageCategoriesPage({
    super.key,
    required this.tabs,
    required this.tab,
    this.loading = false,
    required this.names,
    required this.hidden,
    required this.selected,
    required this.moving,
    required this.scrollController,
    required this.onTap,
  });

  /// Fixed row height (scroll math in the page uses it).
  static const rowExtent = 62.0;

  /// Gap above the first row (also scroll math).
  static const listTop = 14.0;

  /// Section tabs (Live TV / Movies / TV Shows) and the one shown.
  final List<String> tabs;
  final int tab;

  /// The shown section's categories are still loading.
  final bool loading;

  final List<String> names;
  final List<bool> hidden;
  final int selected;

  /// The focused row is picked up: ↑↓ move it.
  final bool moving;
  final ScrollController scrollController;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hiddenCount = hidden.where((h) => h).length;
    return Material(
      color: scheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(28, 18, 28, 14),
            color: scheme.surfaceContainerLow,
            child: Row(
              children: [
                Icon(Icons.category_outlined, color: scheme.primary, size: 28),
                const SizedBox(width: 12),
                Text(
                  'Manage categories',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 28),
                for (var i = 0; i < tabs.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _Tab(label: tabs[i], selected: i == tab),
                  ),
                const Spacer(),
                Text(
                  '${names.length} categories'
                  '${hiddenCount > 0 ? '  ·  $hiddenCount hidden' : ''}',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: names.isEmpty
                ? Center(
                    child: Text(
                      loading ? 'Loading…' : 'No categories from the provider.',
                      style: theme.textTheme.bodyLarge,
                    ),
                  )
                : Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: ListView.builder(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(28, listTop, 28, 24),
                        itemExtent: rowExtent,
                        itemCount: names.length,
                        itemBuilder: (context, i) => _CategoryRow(
                          name: names[i],
                          hidden: hidden[i],
                          focused: i == selected,
                          moving: moving && i == selected,
                          onTap: () => onTap(i),
                        ),
                      ),
                    ),
                  ),
          ),
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 28),
            color: scheme.surfaceContainerLow,
            alignment: Alignment.centerLeft,
            child: Text(
              moving
                  ? '↑↓ move category  ·  A / B drop'
                  : '↑↓ choose  ·  A move  ·  X hide / show  ·  '
                        '${tabs.length > 1 ? 'LB/RB section  ·  ' : ''}B back',
              style: theme.textTheme.labelMedium?.copyWith(
                color: scheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.name,
    required this.hidden,
    required this.focused,
    required this.moving,
    required this.onTap,
  });

  final String name;
  final bool hidden;
  final bool focused;
  final bool moving;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final bg = moving
        ? scheme.tertiary
        : focused
        ? scheme.primary
        : scheme.surfaceContainerHigh;
    final fg = moving
        ? scheme.onTertiary
        : focused
        ? scheme.onPrimary
        : scheme.onSurface.withValues(alpha: hidden ? 0.45 : 1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                moving ? Icons.swap_vert_rounded : Icons.drag_indicator_rounded,
                color: fg.withValues(alpha: moving ? 1 : 0.5),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: fg,
                    fontWeight: focused ? FontWeight.w800 : FontWeight.w600,
                  ),
                ),
              ),
              if (hidden)
                Row(
                  children: [
                    Icon(Icons.visibility_off_outlined, size: 18, color: fg),
                    const SizedBox(width: 6),
                    Text(
                      'Hidden',
                      style: theme.textTheme.labelLarge?.copyWith(color: fg),
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: selected ? scheme.primary : scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: selected ? scheme.onPrimary : scheme.onSurface,
          fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
        ),
      ),
    );
  }
}
