import 'dart:async';
import 'dart:io' show exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sdtv_core/sdtv_core.dart';
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
      if (session.browseCategories.isNotEmpty &&
          session.selectedCategoryId == null) {
        session.selectCategory(session.browseCategories.first.categoryId);
      }
      // Align index with session selection (e.g. open on Favorites).
      final sel = session.selectedCategoryId;
      if (sel != null) {
        final i =
            session.browseCategories.indexWhere((c) => c.categoryId == sel);
        if (i >= 0) setState(() => _catIndex = i);
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
    final catCount = session.browseCategories.length;
    final chanCount = session.channelsInCategory.length;
    if (catCount > 0) {
      _catIndex = _catIndex.clamp(0, catCount - 1);
      // Keep catIndex aligned with selectedCategoryId when session changes.
      final sel = session.selectedCategoryId;
      if (sel != null) {
        final i = session.browseCategories.indexWhere((c) => c.categoryId == sel);
        if (i >= 0) _catIndex = i;
      }
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
    // Phase B: while watching, ↑↓ = volume (pad still owned by Flutter on Deck).
    // delta < 0 = up → louder; delta > 0 = down → quieter.
    if (session.isWatchingExternal && !_menuOpen && !_aboutOpen) {
      unawaited(session.watchVolumeDelta(delta < 0 ? 5 : -5));
      return;
    }

    if (!_acceptNav()) return;

    // Menu / about overlays own the D-pad.
    if (_aboutOpen) return;
    if (_menuOpen) {
      setState(() {
        _menuIndex = (_menuIndex + delta).clamp(0, _menuItems.length - 1);
      });
      return;
    }

    final cats = session.browseCategories;
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
    // Phase B: while watching, ←/→ = previous / next channel.
    if (session.isWatchingExternal && !_menuOpen && !_aboutOpen) {
      unawaited(session.watchChannelAdjacent(delta));
      return;
    }

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

  void _onPage(int delta) {
    if (session.isWatchingExternal) {
      unawaited(session.watchChannelAdjacent(delta));
      return;
    }
    // Guide: shoulders move category or channel list like page jumps.
    if (_menuOpen || _aboutOpen) return;
    if (_column == 0) {
      _moveVertical(delta);
    } else {
      _moveVertical(delta * 5);
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

    // While mpv is up, A = pause (never freeze the guide / menu).
    if (session.isWatchingExternal) {
      if (_menuOpen || _aboutOpen) {
        // Overlays still need A; if we somehow have UI + watch flag, clear watch.
        await session.watchQuit();
      } else {
        await session.watchCyclePause();
      }
      return;
    }

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
      final cats = session.browseCategories;
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

    // Channels: hand off to external fullscreen mpv (Phase A).
    // Re-entry while watching is handled above + session.watchChannel guard.
    final chans = session.channelsInCategory;
    if (chans.isEmpty) return;
    final ch = chans[_chanIndex.clamp(0, chans.length - 1)];

    final err = await session.watchChannel(ch);
    if (!mounted) return;

    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(err),
          duration: const Duration(seconds: 6),
          action: SnackBarAction(
            label: 'Embedded',
            onPressed: () {
              unawaited(_playEmbedded(ch));
            },
          ),
        ),
      );
    }

    if (mounted) setState(() => _column = 1);
  }

  /// Fallback: old Flutter texture player (debug / no system mpv).
  Future<void> _playEmbedded(LiveChannel ch) async {
    await session.playChannel(ch);
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(session: session),
      ),
    );
    if (!mounted) return;
    try {
      await session.stopPlayback(notify: false).timeout(
            const Duration(seconds: 2),
          );
    } catch (e) {
      debugPrint('sdtv: stop after embedded player: $e');
    }
    if (mounted) setState(() => _column = 1);
  }

  /// Hierarchical back: about → menu → categories ← channels.
  /// While external mpv is up: B quits video (does not open the guide menu).
  void _onBack() {
    if (session.isWatchingExternal) {
      unawaited(session.watchQuit());
      return;
    }
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

  /// Y / F: star or unstar the focused channel (channel column only).
  Future<void> _toggleFavorite() async {
    if (session.isWatchingExternal) return;
    if (_menuOpen || _aboutOpen) return;
    if (_column != 1) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Move to a channel, then press Y to favorite'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final chans = session.channelsInCategory;
    if (chans.isEmpty) return;
    final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
    final nowFav = await session.toggleFavorite(ch);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(nowFav ? '★ ${ch.name}' : '☆ Removed ${ch.name}'),
        duration: const Duration(seconds: 2),
      ),
    );
    // If we unstarred the last item while in Favorites, index may be empty.
    setState(() {});
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
    final cats = session.browseCategories;
    final channels = session.channelsInCategory;
    final user = session.userInfo?.username ?? 'user';
    final catTitle = cats.isEmpty
        ? 'All'
        : cats[_catIndex.clamp(0, cats.length - 1)].categoryName;

    return SdtvInputScope(
      onBack: _onBack,
      onMenu: _openMenu,
      onFavorite: () {
        unawaited(_toggleFavorite());
      },
      onMute: () {
        if (session.isWatchingExternal) {
          unawaited(session.watchCycleMute());
        }
      },
      onPageUp: () => _onPage(-1),
      onPageDown: () => _onPage(1),
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
                                : session.useM3u
                                    ? 'M3U'
                                    : session.mockCatalog
                                        ? 'MOCK'
                                        : 'LIVE',
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
                              final isFavCat =
                                  cats[i].categoryId == kFavoritesCategoryId;
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _BrowseTile(
                                  label: isFavCat
                                      ? '${cats[i].categoryName}'
                                          '${session.favoriteCount > 0 ? ' (${session.favoriteCount})' : ''}'
                                      : cats[i].categoryName,
                                  icon: isFavCat
                                      ? Icons.star_rounded
                                      : Icons.folder_outlined,
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
                                final emptyMsg = session.isFavoritesCategory
                                    ? 'No favorites yet.\n'
                                        'Open any category · highlight a channel · Y to star'
                                    : 'No channels.\n→ not needed · A opens list · ← back';
                                return Text(
                                  emptyMsg,
                                  style: theme.textTheme.bodyLarge,
                                );
                              }
                              final i = index - 1;
                              final ch = channels[i];
                              final selected =
                                  _column == 1 && _chanIndex == i;
                              final fav = session.isFavorite(ch);
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: _BrowseTile(
                                  label:
                                      '${ch.num > 0 ? '${ch.num}. ' : ''}${ch.name}',
                                  icon: fav
                                      ? Icons.star_rounded
                                      : Icons.live_tv_outlined,
                                  selected: selected,
                                  onTap: () async {
                                    setState(() {
                                      _column = 1;
                                      _chanIndex = i;
                                    });
                                    await _activate();
                                  },
                                  onLongPress: () async {
                                    setState(() {
                                      _column = 1;
                                      _chanIndex = i;
                                    });
                                    await _toggleFavorite();
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
                          ? '↑↓ channels · A play · Y favorite · ← or B categories · ☰ menu'
                          : '↑↓ categories · → or A channels · B menu · Y = star channel',
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
                              'sdtv — Steam Deck IPTV player.\n'
                              'Demo = offline mock. M3U = playlist URL. '
                              'Connect = Xtream panel.\n'
                              'You supply legal playlists/credentials only.\n\n'
                              'Signed in as $user'
                              '${session.useDemo ? ' (demo)' : session.useM3u ? ' (m3u)' : session.mockCatalog ? ' (mock)' : ' (live)'}\n'
                              'Channels: ${session.allChannels.length}\n\n'
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
    this.onLongPress,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
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
      onLongPress: onLongPress,
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
