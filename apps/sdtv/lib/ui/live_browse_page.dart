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

  /// Last channel row per category id (so ← categories → channels keeps place).
  final Map<String, int> _chanIndexByCategory = {};

  /// In-page menu (no showDialog — avoids stuck modal barriers on Deck).
  bool _menuOpen = false;
  bool _aboutOpen = false;
  bool _manageCatsOpen = false;
  bool _searchOpen = false;
  int _menuIndex = 0;
  int _manageIndex = 0;
  int _searchIndex = 0;

  final _catScroll = ScrollController();
  final _chanScroll = ScrollController();
  final _manageScroll = ScrollController();
  final _searchScroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final _searchFocus = FocusNode();
  List<GuideSearchHit> _searchHits = const [];

  DateTime? _lastNavAt;
  // Allow accelerated hold-scroll from the joystick reader (~40ms + bursts).
  static const _navCooldown = Duration(milliseconds: 28);

  static const _menuItems = <({String id, String label, IconData icon})>[
    (id: 'search', label: 'Search', icon: Icons.search),
    (id: 'hide_cat', label: 'Hide category', icon: Icons.visibility_off_outlined),
    (id: 'manage_cats', label: 'Manage categories', icon: Icons.category_outlined),
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
    _searchCtrl.addListener(_onSearchQueryChanged);
    SdtvTextFocusRegistry.register(_searchFocus);
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
    _searchCtrl.removeListener(_onSearchQueryChanged);
    SdtvTextFocusRegistry.unregister(_searchFocus);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    _catScroll.dispose();
    _chanScroll.dispose();
    _manageScroll.dispose();
    _searchScroll.dispose();
    super.dispose();
  }

  void _onSearchQueryChanged() {
    if (!_searchOpen) return;
    final hits = session.searchGuide(_searchCtrl.text);
    setState(() {
      _searchHits = hits;
      _searchIndex = hits.isEmpty ? 0 : _searchIndex.clamp(0, hits.length - 1);
    });
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
      _rememberChanIndex();
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

  void _rememberChanIndex() {
    final id = session.selectedCategoryId;
    if (id == null) return;
    _chanIndexByCategory[id] = _chanIndex;
  }

  /// Restore last channel row for [categoryId] (clamped to list length).
  int _chanIndexFor(String categoryId, int listLength) {
    if (listLength <= 0) return 0;
    final saved = _chanIndexByCategory[categoryId] ?? 0;
    return saved.clamp(0, listLength - 1);
  }

  /// Switch provider category, keeping each list's remembered position.
  void _selectCategoryKeepingChanPos(String categoryId) {
    _rememberChanIndex();
    session.selectCategory(categoryId);
    final n = session.channelsInCategory.length;
    _chanIndex = _chanIndexFor(categoryId, n);
  }

  void _enterChannelColumn() {
    final id = session.selectedCategoryId;
    final n = session.channelsInCategory.length;
    final idx = id == null ? 0 : _chanIndexFor(id, n);
    setState(() {
      _column = 1;
      _chanIndex = idx;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _scrollTo(_chanScroll, idx);
    });
  }

  void _moveVertical(int delta) {
    // Watching + menu open: D-pad navigates the pause menu (not volume).
    if (session.isWatchMenuActive &&
        !_menuOpen &&
        !_aboutOpen &&
        !_manageCatsOpen &&
        !_searchOpen) {
      unawaited(session.watchMenuMove(delta));
      return;
    }
    // Watching, menu closed: ↑↓ = volume.
    // delta < 0 = up → louder; delta > 0 = down → quieter.
    if (session.isWatchingExternal &&
        !_menuOpen &&
        !_aboutOpen &&
        !_manageCatsOpen &&
        !_searchOpen) {
      unawaited(session.watchVolumeDelta(delta < 0 ? 5 : -5));
      return;
    }

    if (!_acceptNav()) return;

    // Menu / about / manage / search overlays own the D-pad.
    if (_aboutOpen) return;
    if (_searchOpen) {
      if (_searchHits.isEmpty) return;
      // Leave the text field so arrows move results, not caret.
      _searchFocus.unfocus();
      setState(() {
        _searchIndex =
            (_searchIndex + delta).clamp(0, _searchHits.length - 1);
      });
      _scrollTo(_searchScroll, _searchIndex);
      return;
    }
    if (_manageCatsOpen) {
      final n = session.categories.length;
      if (n == 0) return;
      setState(() {
        _manageIndex = (_manageIndex + delta).clamp(0, n - 1);
      });
      _scrollTo(_manageScroll, _manageIndex);
      return;
    }
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
      _selectCategoryKeepingChanPos(cats[_catIndex].categoryId);
      _scrollTo(_catScroll, _catIndex);
    } else {
      if (chans.isEmpty) return;
      setState(() {
        _chanIndex = (_chanIndex + delta).clamp(0, chans.length - 1);
      });
      _rememberChanIndex();
      _scrollTo(_chanScroll, _chanIndex);
    }
  }

  void _moveHorizontal(int delta) {
    // Watching + menu: ←/→ adjust current row (subs / audio / mute).
    if (session.isWatchMenuActive &&
        !_menuOpen &&
        !_aboutOpen &&
        !_manageCatsOpen &&
        !_searchOpen) {
      unawaited(session.watchMenuAdjust(delta));
      return;
    }
    // Watching, menu closed: ←/→ = previous / next channel.
    if (session.isWatchingExternal &&
        !_menuOpen &&
        !_aboutOpen &&
        !_manageCatsOpen &&
        !_searchOpen) {
      unawaited(session.watchChannelAdjacent(delta));
      return;
    }

    if (_menuOpen || _aboutOpen || _manageCatsOpen || _searchOpen) return;
    if (!_acceptNav()) return;
    if (delta > 0 && _column == 0) {
      _enterChannelColumn();
    } else if (delta < 0 && _column == 1) {
      _rememberChanIndex();
      setState(() => _column = 0);
      _scrollTo(_catScroll, _catIndex);
    }
  }

  void _onPage(int delta) {
    if (session.isWatchMenuActive) {
      unawaited(session.watchMenuMove(delta));
      return;
    }
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

    // While mpv is up: A opens/activates the watch menu (not the guide menu).
    if (session.isWatchingExternal) {
      if (_menuOpen || _aboutOpen || _manageCatsOpen || _searchOpen) {
        await session.watchQuit();
      } else {
        await session.watchActivate();
      }
      return;
    }

    if (_aboutOpen) {
      setState(() => _aboutOpen = false);
      return;
    }

    if (_searchOpen) {
      await _activateSearchHit();
      return;
    }

    if (_manageCatsOpen) {
      await _toggleManageRow();
      return;
    }

    if (_menuOpen) {
      await _runMenuAction(_menuItems[_menuIndex].id);
      return;
    }

    // Categories: enter channel column only (restore last row for this cat).
    if (_column == 0) {
      final cats = session.browseCategories;
      if (cats.isEmpty) return;
      _selectCategoryKeepingChanPos(cats[_catIndex].categoryId);
      _enterChannelColumn();
      return;
    }

    // Channels: hand off to external fullscreen mpv (Phase A).
    // Re-entry while watching is handled above + session.watchChannel guard.
    final chans = session.channelsInCategory;
    if (chans.isEmpty) return;
    final ch = chans[_chanIndex.clamp(0, chans.length - 1)];
    _rememberChanIndex();

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

    if (mounted) {
      setState(() => _column = 1);
      _scrollTo(_chanScroll, _chanIndex);
    }
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

  /// Hierarchical back: about → manage → menu → categories ← channels.
  /// While watching: B closes watch menu first, else quits to guide.
  void _onBack() {
    if (session.isWatchingExternal) {
      unawaited(session.watchBack());
      return;
    }
    if (_aboutOpen) {
      setState(() => _aboutOpen = false);
      return;
    }
    if (_searchOpen) {
      _closeSearch();
      return;
    }
    if (_manageCatsOpen) {
      setState(() => _manageCatsOpen = false);
      return;
    }
    if (_menuOpen) {
      setState(() => _menuOpen = false);
      return;
    }
    // In channel list: step back to categories (don't open system menu).
    if (_column == 1) {
      if (!_acceptNav()) return;
      _rememberChanIndex();
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
    if (_searchOpen) {
      _closeSearch();
      return;
    }
    if (_manageCatsOpen) {
      setState(() => _manageCatsOpen = false);
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

  void _openSearch() {
    if (session.isWatchingExternal) return;
    setState(() {
      _menuOpen = false;
      _aboutOpen = false;
      _manageCatsOpen = false;
      _searchOpen = true;
      _searchIndex = 0;
      _searchHits = session.searchGuide(_searchCtrl.text);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocus.requestFocus();
      // Opening via `/` can insert a slash into the field — strip it.
      final t = _searchCtrl.text;
      if (t.startsWith('/')) {
        _searchCtrl.text = t.substring(1);
        _searchCtrl.selection = TextSelection.collapsed(
          offset: _searchCtrl.text.length,
        );
      }
    });
  }

  void _closeSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searchOpen = false;
      _searchIndex = 0;
    });
  }

  Future<void> _activateSearchHit() async {
    if (_searchHits.isEmpty) return;
    final hit = _searchHits[_searchIndex.clamp(0, _searchHits.length - 1)];
    await _applySearchHit(hit);
  }

  Future<void> _applySearchHit(GuideSearchHit hit) async {
    // EPG hits: navigate when implemented; for now no-op with room to extend.
    if (hit.isEpg) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('EPG search coming later'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final catId = hit.categoryId;
    if (catId == null || catId.isEmpty) return;

    // Jump guide to this category / channel.
    final cats = session.browseCategories;
    var catIdx = cats.indexWhere((c) => c.categoryId == catId);
    // Hidden cat shouldn't appear in search; if only channel matched via
    // allChannels, still select raw id.
    if (catIdx < 0 && catId != kFavoritesCategoryId) {
      // Category hidden or missing — still try to select for channel play.
      session.selectCategory(catId);
    } else if (catIdx >= 0) {
      _selectCategoryKeepingChanPos(catId);
      catIdx = session.browseCategories
          .indexWhere((c) => c.categoryId == catId);
    } else if (catId == kFavoritesCategoryId) {
      _selectCategoryKeepingChanPos(kFavoritesCategoryId);
      catIdx = 0;
    }

    final browse = session.browseCategories;
    final resolvedCat = browse.indexWhere((c) => c.categoryId == catId);
    if (resolvedCat >= 0) {
      _catIndex = resolvedCat;
    }

    if (hit.isChannel && hit.channel != null) {
      final list = session.channelsInCategory;
      var chIdx = list.indexWhere(
        (c) => c.favoriteKey == hit.channel!.favoriteKey,
      );
      if (chIdx < 0) {
        // Channel may live in another group; use allChannels position in cat.
        chIdx = list.indexWhere((c) => c.streamId == hit.channel!.streamId);
      }
      if (chIdx < 0) chIdx = 0;
      _chanIndex = chIdx;
      _chanIndexByCategory[catId] = chIdx;
      _closeSearch();
      setState(() => _column = 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollTo(_chanScroll, chIdx);
      });
      // Play immediately — search is for getting to content fast.
      final err = await session.watchChannel(hit.channel!);
      if (!mounted) return;
      if (err != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(err), duration: const Duration(seconds: 5)),
        );
      }
      return;
    }

    // Category hit: open that list at remembered/top position.
    _closeSearch();
    _enterChannelColumn();
  }

  Future<void> _runMenuAction(String id) async {
    setState(() => _menuOpen = false);
    if (id == 'cancel') return;
    if (id == 'search') {
      _openSearch();
      return;
    }
    if (id == 'hide_cat') {
      await _hideFocusedCategory();
      return;
    }
    if (id == 'manage_cats') {
      setState(() {
        _manageCatsOpen = true;
        _manageIndex = 0;
      });
      return;
    }
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

  /// Hide the category under the guide cursor (not ★ Favorites).
  Future<void> _hideFocusedCategory() async {
    if (session.isWatchingExternal) return;
    final cats = session.browseCategories;
    if (cats.isEmpty) return;
    // Prefer category column selection; if on channels, hide that category.
    final idx = _catIndex.clamp(0, cats.length - 1);
    final cat = cats[idx];
    if (cat.categoryId == kFavoritesCategoryId) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('★ Favorites cannot be hidden'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }
    final name = cat.categoryName;
    await session.hideCategory(cat.categoryId);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Hidden: $name · ☰ Manage categories to restore'),
        duration: const Duration(seconds: 3),
      ),
    );
    setState(() {
      _column = 0;
    });
  }

  Future<void> _toggleManageRow() async {
    final all = session.categories;
    if (all.isEmpty) return;
    final i = _manageIndex.clamp(0, all.length - 1);
    final cat = all[i];
    // No SnackBar here — bulk hide would queue dozens of toasts.
    // Tile label/icon + header counts already update in place.
    await session.toggleCategoryHidden(cat.categoryId);
    if (mounted) setState(() {});
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
      onSearch: _openSearch,
      onFavorite: () {
        unawaited(_toggleFavorite());
      },
      onMute: () {
        if (session.isWatchingExternal) {
          unawaited(session.watchCycleMute());
        } else if (_searchOpen) {
          // Don't hide cats while typing search.
        } else if (_manageCatsOpen) {
          unawaited(_toggleManageRow());
        } else if (!_menuOpen && !_aboutOpen) {
          // Guide: X hides the focused category (quick junk filter).
          unawaited(_hideFocusedCategory());
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
                                final hiddenN = session.hiddenCategoryCount;
                                return Padding(
                                  padding: const EdgeInsets.only(bottom: 12),
                                  child: Text(
                                    hiddenN > 0
                                        ? 'CATEGORIES · $hiddenN hidden'
                                        : 'CATEGORIES',
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
                                    _selectCategoryKeepingChanPos(
                                      cats[i].categoryId,
                                    );
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
                                    _rememberChanIndex();
                                    await _activate();
                                  },
                                  onLongPress: () async {
                                    setState(() {
                                      _column = 1;
                                      _chanIndex = i;
                                    });
                                    _rememberChanIndex();
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
                          ? '↑↓ channels · A play · Y favorite · / search · ☰ menu'
                          : '↑↓ cats · A open · / search · X hide · ☰ menu',
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

              // —— Guide search (categories + channels; EPG later) ——
              if (_searchOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: _closeSearch,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 560,
                      maxHeight: 560,
                    ),
                    child: Material(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      elevation: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Search',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Categories & channels'
                              '${session.hiddenCategoryCount > 0 ? ' · hidden cats excluded' : ''}'
                              ' · EPG later',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.outline,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _searchCtrl,
                              focusNode: _searchFocus,
                              autofocus: true,
                              style: theme.textTheme.titleMedium,
                              decoration: InputDecoration(
                                hintText: 'e.g. bloomberg, espn, usa…',
                                prefixIcon: const Icon(Icons.search),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                filled: true,
                              ),
                              textInputAction: TextInputAction.search,
                              onSubmitted: (_) {
                                unawaited(_activateSearchHit());
                              },
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: _searchCtrl.text.trim().isEmpty
                                  ? Text(
                                      'Type to filter. ↑↓ results · A open/play · B close',
                                      style: theme.textTheme.bodyLarge,
                                    )
                                  : _searchHits.isEmpty
                                      ? Text(
                                          'No matches for “${_searchCtrl.text.trim()}”',
                                          style: theme.textTheme.bodyLarge,
                                        )
                                      : ListView.builder(
                                          controller: _searchScroll,
                                          itemCount: _searchHits.length,
                                          itemBuilder: (context, i) {
                                            final hit = _searchHits[i];
                                            final selected = _searchIndex == i;
                                            final icon = hit.isCategory
                                                ? Icons.folder_outlined
                                                : hit.isEpg
                                                    ? Icons.event_outlined
                                                    : Icons.live_tv_outlined;
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                bottom: 8,
                                              ),
                                              child: _BrowseTile(
                                                label: hit.subtitle.isEmpty
                                                    ? hit.title
                                                    : '${hit.title}\n${hit.subtitle}',
                                                icon: icon,
                                                selected: selected,
                                                onTap: () async {
                                                  setState(
                                                    () => _searchIndex = i,
                                                  );
                                                  await _applySearchHit(hit);
                                                },
                                              ),
                                            );
                                          },
                                        ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '↑↓ results · A select · B close · Steam+X OSK on Deck',
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

              // —— Manage categories (show / hide) ——
              if (_manageCatsOpen) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _manageCatsOpen = false),
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                    ),
                  ),
                ),
                Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      maxWidth: 480,
                      maxHeight: 520,
                    ),
                    child: Material(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      elevation: 12,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Manage categories',
                              style: theme.textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'A toggles hide/show · Hidden stay off the guide.\n'
                              'Hidden: ${session.hiddenCategoryCount} · '
                              'Visible: ${session.visibleCategories.length}',
                              style: theme.textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            Expanded(
                              child: session.categories.isEmpty
                                  ? Text(
                                      'No categories from provider.',
                                      style: theme.textTheme.bodyLarge,
                                    )
                                  : ListView.builder(
                                      controller: _manageScroll,
                                      itemCount: session.categories.length,
                                      itemBuilder: (context, i) {
                                        final cat = session.categories[i];
                                        final hidden =
                                            session.isCategoryHidden(
                                          cat.categoryId,
                                        );
                                        final selected = _manageIndex == i;
                                        return Padding(
                                          padding: const EdgeInsets.only(
                                            bottom: 8,
                                          ),
                                          child: _BrowseTile(
                                            label: hidden
                                                ? '${cat.categoryName}  · hidden'
                                                : cat.categoryName,
                                            icon: hidden
                                                ? Icons.visibility_off_outlined
                                                : Icons.visibility_outlined,
                                            selected: selected,
                                            onTap: () async {
                                              setState(() => _manageIndex = i);
                                              await _toggleManageRow();
                                            },
                                          ),
                                        );
                                      },
                                    ),
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '↑↓ move · A toggle · B close',
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
