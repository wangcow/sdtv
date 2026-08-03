import 'dart:async';
import 'dart:io' show exit;

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

  /// In-page menu (no showDialog — avoids stuck modal barriers on Deck).
  bool _menuOpen = false;
  bool _aboutOpen = false;
  int _menuIndex = 0;

  final _catScroll = ScrollController();
  final _chanScroll = ScrollController();

  DateTime? _lastNavAt;
  static const _navCooldown = Duration(milliseconds: 200);

  static const _menuItems = <({String id, String label, IconData icon})>[
    (id: 'about', label: 'About', icon: Icons.info_outline),
    (id: 'signout', label: 'Sign out', icon: Icons.logout),
    (id: 'exit', label: 'Exit sdtv', icon: Icons.power_settings_new),
    (id: 'cancel', label: 'Cancel', icon: Icons.close),
  ];

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
    final catCount = session.categories.length;
    final chanCount = session.channelsInCategory.length;
    if (catCount > 0) {
      _catIndex = _catIndex.clamp(0, catCount - 1);
    } else {
      _catIndex = 0;
    }
    if (chanCount > 0) {
      _chanIndex = _chanIndex.clamp(0, chanCount - 1);
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

    // Menu / about overlays own the D-pad.
    if (_aboutOpen) return;
    if (_menuOpen) {
      setState(() {
        _menuIndex = (_menuIndex + delta).clamp(0, _menuItems.length - 1);
      });
      return;
    }

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
    if (_menuOpen || _aboutOpen) return;
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

  DateTime? _lastActivateAt;

  Future<void> _activate() async {
    // Belt-and-suspenders vs dual js+Enter on Deck.
    final now = DateTime.now();
    if (_lastActivateAt != null &&
        now.difference(_lastActivateAt!) < const Duration(milliseconds: 280)) {
      return;
    }
    _lastActivateAt = now;

    if (_aboutOpen) {
      setState(() => _aboutOpen = false);
      return;
    }

    if (_menuOpen) {
      await _runMenuAction(_menuItems[_menuIndex].id);
      return;
    }

    // Categories: enter channel column only.
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

    // Channels: play.
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

    if (!mounted) return;
    // Timed stop — unbounded mpv stop after bipbop was freezing the UI on B.
    try {
      await session.stopPlayback(notify: false).timeout(
            const Duration(seconds: 2),
          );
    } catch (e) {
      debugPrint('sdtv: stop after player: $e');
    }
    if (!mounted) return;
    setState(() => _column = 1);
  }

  /// Hierarchical back: about → menu → categories ← channels ← (player pops itself).
  /// Menu only when already on the category column.
  void _onBack() {
    if (_aboutOpen) {
      setState(() => _aboutOpen = false);
      return;
    }
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    // In channel list: step back to categories (don't open system menu).
    if (_column == 1) {
      if (!_acceptNav()) return;
      setState(() => _column = 0);
      _scrollTo(_catScroll, _catIndex);
      return;
    }
    // Category list: open menu.
    setState(() {
      _menuOpen = true;
      _menuIndex = 0;
    });
  }

  void _openMenu() {
    // ☰ / Start always opens menu (or closes overlay if one is up).
    if (_aboutOpen) {
      setState(() => _aboutOpen = false);
      return;
    }
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    setState(() {
      _menuOpen = true;
      _menuIndex = 0;
    });
  }

  Future<void> _runMenuAction(String id) async {
    setState(() => _menuOpen = false);
    if (id == 'cancel') return;
    if (id == 'about') {
      setState(() => _aboutOpen = true);
      return;
    }
    if (id == 'signout') {
      await session.signOut();
      return;
    }
    if (id == 'exit') {
      await _exitApp();
    }
  }

  /// Quit the process so Game Mode returns to Steam (no STEAM → Exit game).
  Future<void> _exitApp() async {
    try {
      await session.stopPlayback(notify: false).timeout(
            const Duration(seconds: 1),
          );
    } catch (e) {
      debugPrint('sdtv: stop before exit: $e');
    }
    try {
      await session.player.dispose().timeout(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('sdtv: dispose before exit: $e');
    }
    // Linux desktop / Deck: SystemNavigator.pop is unreliable; exit the process.
    exit(0);
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
      onBack: _onBack,
      onMenu: _openMenu,
      onConfirm: () {
        unawaited(_activate());
      },
      onDirection: (dir) {
        switch (dir) {
          case TraversalDirection.up:
            _moveVertical(-1);
          case TraversalDirection.down:
            _moveVertical(1);
          case TraversalDirection.left:
            _moveHorizontal(-1);
          case TraversalDirection.right:
            _moveHorizontal(1);
        }
      },
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
          child: Stack(
            children: [
              Column(
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
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Text(
                            session.useDemo
                                ? 'DEMO'
                                : session.mockCatalog
                                    ? 'MOCK CATALOG'
                                    : 'LIVE TV',
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
                                    session
                                        .selectCategory(cats[i].categoryId);
                                    _chanIndex = 0;
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                        VerticalDivider(
                          width: 1,
                          color: theme.colorScheme.outline
                              .withValues(alpha: 0.3),
                        ),
                        Expanded(
                          child: ListView.builder(
                            controller: _chanScroll,
                            padding: const EdgeInsets.fromLTRB(16, 8, 24, 24),
                            itemCount:
                                channels.isEmpty ? 2 : channels.length + 1,
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
                                  'No channels.\n→ not needed · A opens list · ← back',
                                  style: theme.textTheme.bodyLarge,
                                );
                              }
                              final i = index - 1;
                              final ch = channels[i];
                              final selected =
                                  _column == 1 && _chanIndex == i;
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
                                    await _activate();
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
                          color: theme.colorScheme.outline
                              .withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                    child: Text(
                      _column == 1
                          ? '↑↓ channels · ← or B categories · A play · ☰ menu'
                          : '↑↓ categories · → or A channels · B menu',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),

              // —— In-page menu (no Navigator dialog) ——
              if (_menuOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _menuOpen = false),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 400),
                    child: Material(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      elevation: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Menu',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Signed in as $user'
                              '${session.useDemo ? ' (demo)' : ''}',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 20),
                            for (var i = 0; i < _menuItems.length; i++) ...[
                              if (i > 0) const SizedBox(height: 8),
                              _BrowseTile(
                                label: _menuItems[i].label,
                                icon: _menuItems[i].icon,
                                selected: _menuIndex == i,
                                onTap: () =>
                                    _runMenuAction(_menuItems[i].id),
                              ),
                            ],
                            const SizedBox(height: 12),
                            Text(
                              '↑↓ move · A select · B close',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],

              // —— In-page about ——
              if (_aboutOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _aboutOpen = false),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Material(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      elevation: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'About sdtv',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Live TV browse (MVP).\n'
                              'Without SDTV_ALLOW_LIVE=1, Connect uses the '
                              'mock catalog + public demo stream (not your '
                              'provider).\n\n'
                              'Signed in as $user'
                              '${session.useDemo ? ' (demo)' : session.mockCatalog ? ' (mock)' : ' (live)'}\n\n'
                              'Product of the Wangcow Corporation\n'
                              'Apache License 2.0',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 20),
                            _BrowseTile(
                              label: 'Close',
                              icon: Icons.close,
                              selected: true,
                              onTap: () =>
                                  setState(() => _aboutOpen = false),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'A or B to close',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
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
