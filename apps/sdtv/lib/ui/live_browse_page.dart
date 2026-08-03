import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_input/sdtv_input.dart';

import '../state/session_controller.dart';
import 'player_page.dart';

/// Two-column live browser with explicit index navigation (TV / Deck).
class LiveBrowsePage extends StatefulWidget {
  const LiveBrowsePage({super.key, required this.session});

  final SessionController session;

  @override
  State<LiveBrowsePage> createState() => _LiveBrowsePageState();
}

class _LiveBrowsePageState extends State<LiveBrowsePage> {
  /// 0 = categories, 1 = channels
  int _column = 0;
  int _catIndex = 0;
  int _chanIndex = 0;

  final _catScroll = ScrollController();
  final _chanScroll = ScrollController();

  DateTime? _lastNavAt;
  static const _navCooldown = Duration(milliseconds: 200);

  SessionController get session => widget.session;

  bool _acceptNav() {
    final now = DateTime.now();
    if (_lastNavAt != null && now.difference(_lastNavAt!) < _navCooldown) {
      return false;
    }
    _lastNavAt = now;
    return true;
  }

  @override
  void initState() {
    super.initState();
    session.addListener(_onSession);
    // Defer so we never notify during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (session.categories.isNotEmpty &&
          session.selectedCategoryId == null) {
        session.selectCategory(session.categories.first.categoryId);
      }
    });
  }

  @override
  void dispose() {
    session.removeListener(_onSession);
    _catScroll.dispose();
    _chanScroll.dispose();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    final cats = session.categories.length;
    final chans = session.channelsInCategory.length;
    if (cats > 0) {
      _catIndex = _catIndex.clamp(0, cats - 1);
    } else {
      _catIndex = 0;
    }
    if (chans > 0) {
      _chanIndex = _chanIndex.clamp(0, chans - 1);
    } else {
      _chanIndex = 0;
    }
    setState(() {});
  }

  void _scrollTo(ScrollController c, int index) {
    if (!c.hasClients) return;
    final offset = (index * 72.0).clamp(0.0, c.position.maxScrollExtent);
    c.animateTo(
      offset,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  void _moveVertical(int delta) {
    if (!_acceptNav()) return;
    final cats = session.categories;
    final chans = session.channelsInCategory;

    if (_column == 0) {
      if (cats.isEmpty) return;
      setState(() {
        _catIndex = (_catIndex + delta).clamp(0, cats.length - 1);
      });
      session.selectCategory(cats[_catIndex].categoryId);
      _chanIndex = 0;
      _scrollTo(_catScroll, _catIndex);
    } else {
      if (chans.isEmpty) return;
      setState(() {
        _chanIndex = (_chanIndex + delta).clamp(0, chans.length - 1);
      });
      _scrollTo(_chanScroll, _chanIndex);
    }
  }

  void _moveHorizontal(int delta) {
    if (!_acceptNav()) return;
    if (delta > 0 && _column == 0) {
      setState(() {
        _column = 1;
        _chanIndex = 0;
      });
      _scrollTo(_chanScroll, 0);
    } else if (delta < 0 && _column == 1) {
      setState(() => _column = 0);
      _scrollTo(_catScroll, _catIndex);
    }
  }

  /// A: categories → enter channel list; channels → play.
  Future<void> _activate() async {
    if (_column == 0) {
      final cats = session.categories;
      if (cats.isEmpty) return;
      session.selectCategory(cats[_catIndex].categoryId);
      setState(() {
        _column = 1;
        _chanIndex = 0;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollTo(_chanScroll, 0);
      });
      return;
    }

    final chans = session.channelsInCategory;
    if (chans.isEmpty) return;
    final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
    await session.playChannel(ch);
    if (!mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(session: session),
      ),
    );

    // Back from player: stay on channel list, don't jump columns.
    if (!mounted) return;
    await session.stopPlayback(notify: false);
    setState(() {
      // Keep column on channels so user continues browsing this category.
      _column = 1;
    });
  }

  Future<void> _openSystemMenu() async {
    // Close an existing dialog first.
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }

    final user = session.userInfo?.username ?? 'user';
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => _IndexMenuDialog(
        title: 'Menu',
        subtitle: 'Signed in as $user${session.useDemo ? ' (demo)' : ''}',
        items: const [
          (id: 'about', label: 'About', icon: Icons.info_outline),
          (id: 'signout', label: 'Sign out', icon: Icons.logout),
          (id: 'cancel', label: 'Cancel', icon: Icons.close),
        ],
      ),
    );

    if (!mounted) return;

    if (action == 'about') {
      await showDialog<void>(
        context: context,
        builder: (ctx) => _IndexMenuDialog(
          title: 'About sdtv',
          subtitle:
              'Live TV browse (Phase 1).\nDemo/mock catalog.\n\nSigned in as $user'
              '${session.useDemo ? ' (demo)' : ''}\n\n'
              'Product of the Wangcow Corporation',
          items: const [
            (id: 'close', label: 'Close', icon: Icons.close),
          ],
        ),
      );
    } else if (action == 'signout') {
      await session.signOut();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cats = session.categories;
    final channels = session.channelsInCategory;
    final user = session.userInfo?.username ?? 'user';
    final catTitle = cats.isEmpty
        ? 'All'
        : cats[_catIndex.clamp(0, cats.length - 1)].categoryName;

    return SdtvInputScope(
      onBack: _openSystemMenu,
      onMenu: _openSystemMenu,
      onConfirm: _activate,
      extraActions: {
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            switch (intent.direction) {
              case TraversalDirection.up:
                _moveVertical(-1);
              case TraversalDirection.down:
                _moveVertical(1);
              case TraversalDirection.left:
                _moveHorizontal(-1);
              case TraversalDirection.right:
                _moveHorizontal(1);
            }
            return null;
          },
        ),
      },
      extraShortcuts: {
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            const DirectionalFocusIntent(TraversalDirection.up),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            const DirectionalFocusIntent(TraversalDirection.down),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            const DirectionalFocusIntent(TraversalDirection.left),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            const DirectionalFocusIntent(TraversalDirection.right),
      },
      child: Scaffold(
        body: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
                child: Row(
                  children: [
                    Text(
                      'sdtv',
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        session.useDemo ? 'DEMO / MOCK' : 'LIVE TV',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      user,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Categories
                    SizedBox(
                      width: 280,
                      child: ListView.builder(
                        controller: _catScroll,
                        padding: const EdgeInsets.fromLTRB(24, 8, 12, 24),
                        itemCount: cats.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                'CATEGORIES',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            );
                          }
                          final i = index - 1;
                          final selected = _column == 0 && _catIndex == i;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _BrowseTile(
                              label: cats[i].categoryName,
                              icon: Icons.folder_outlined,
                              selected: selected,
                              onTap: () {
                                setState(() {
                                  _catIndex = i;
                                  _column = 0;
                                });
                                session.selectCategory(cats[i].categoryId);
                                _chanIndex = 0;
                              },
                            ),
                          );
                        },
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      color: theme.colorScheme.outline.withValues(alpha: 0.3),
                    ),
                    // Channels
                    Expanded(
                      child: ListView.builder(
                        controller: _chanScroll,
                        padding: const EdgeInsets.fromLTRB(16, 8, 24, 24),
                        itemCount: channels.isEmpty ? 2 : channels.length + 1,
                        itemBuilder: (context, index) {
                          if (index == 0) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                'CHANNELS · $catTitle',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.outline,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            );
                          }
                          if (channels.isEmpty) {
                            return Text(
                              'No channels in this category.\nPress ← to go back.',
                              style: theme.textTheme.bodyLarge,
                            );
                          }
                          final i = index - 1;
                          final ch = channels[i];
                          final selected = _column == 1 && _chanIndex == i;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: _BrowseTile(
                              label:
                                  '${ch.num > 0 ? '${ch.num}. ' : ''}${ch.name}',
                              icon: Icons.live_tv_outlined,
                              selected: selected,
                              onTap: () async {
                                setState(() {
                                  _column = 1;
                                  _chanIndex = i;
                                });
                                await session.playChannel(ch);
                                if (!context.mounted) return;
                                await Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        PlayerPage(session: session),
                                  ),
                                );
                                if (!mounted) return;
                                await session.stopPlayback(notify: false);
                                setState(() => _column = 1);
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                child: Text(
                  '↑↓ list · ←→ columns · A open · B menu',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BrowseTile extends StatelessWidget {
  const _BrowseTile({
    required this.label,
    required this.selected,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = selected
        ? theme.colorScheme.primary
        : theme.colorScheme.surfaceContainerHighest;
    final fg =
        selected ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primaryContainer
                : Colors.transparent,
            width: 3,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.45),
                    blurRadius: 16,
                  ),
                ]
              : null,
        ),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, color: fg, size: 28),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: fg,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Index-based dialog (same pattern as login). D-pad works; A selects; B closes.
class _IndexMenuDialog extends StatefulWidget {
  const _IndexMenuDialog({
    required this.title,
    required this.subtitle,
    required this.items,
  });

  final String title;
  final String subtitle;
  final List<({String id, String label, IconData icon})> items;

  @override
  State<_IndexMenuDialog> createState() => _IndexMenuDialogState();
}

class _IndexMenuDialogState extends State<_IndexMenuDialog> {
  int _index = 0;
  DateTime? _lastNav;
  static const _cooldown = Duration(milliseconds: 200);

  void _nav(int delta) {
    final now = DateTime.now();
    if (_lastNav != null && now.difference(_lastNav!) < _cooldown) return;
    _lastNav = now;
    setState(() {
      _index = (_index + delta).clamp(0, widget.items.length - 1);
    });
  }

  void _choose() {
    Navigator.of(context).pop(widget.items[_index].id);
  }

  @override
  Widget build(BuildContext context) {
    return SdtvInputScope(
      enableGamepad: true,
      onBack: () => Navigator.of(context).pop('cancel'),
      onConfirm: _choose,
      extraActions: {
        DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
          onInvoke: (intent) {
            final forward = intent.direction == TraversalDirection.down ||
                intent.direction == TraversalDirection.right;
            _nav(forward ? 1 : -1);
            return null;
          },
        ),
      },
      child: AlertDialog(
        title: Text(widget.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.subtitle),
            const SizedBox(height: 20),
            for (var i = 0; i < widget.items.length; i++) ...[
              if (i > 0) const SizedBox(height: 8),
              _BrowseTile(
                label: widget.items[i].label,
                icon: widget.items[i].icon,
                selected: _index == i,
                onTap: () => Navigator.of(context).pop(widget.items[i].id),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
