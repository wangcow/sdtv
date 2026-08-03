import 'package:flutter/material.dart';
import 'package:sdtv_input/sdtv_input.dart';

/// Phase 0 screen: prove focus navigation without network or mouse.
class ControllerPlaygroundPage extends StatefulWidget {
  const ControllerPlaygroundPage({super.key});

  @override
  State<ControllerPlaygroundPage> createState() =>
      _ControllerPlaygroundPageState();
}

class _ControllerPlaygroundPageState extends State<ControllerPlaygroundPage> {
  String _status = 'Arrows / D-pad move · Enter / A activate · Esc / B back';
  String _lastAction = '—';
  int _selectedCategory = 0;

  static const _categories = [
    'Entertainment',
    'News',
    'Sports',
    'Favorites',
  ];

  static const _channels = {
    0: ['Mock Entertainment 1', 'Mock Entertainment 2', 'Mock Movies Live'],
    1: ['Mock News 24', 'Mock World News'],
    2: ['Mock Sports HD', 'Mock Stadium'],
    3: ['(empty — add favorites later)'],
  };

  void _setAction(String action) {
    setState(() {
      _lastAction = action;
      _status = action;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final channels = _channels[_selectedCategory] ?? const <String>[];

    // Gamepad binding is on; keyboard still works if pad fails.
    return SdtvInputScope(
      onBack: () => _setAction('Back'),
      onMenu: () => _setAction('Menu'),
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0F14),
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
                        letterSpacing: 1.2,
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
                        'CONTROLLER PLAYGROUND',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Phase 0',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  _status,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: FocusTraversalGroup(
                  policy: OrderedTraversalPolicy(),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Categories column
                      SizedBox(
                        width: 260,
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(24, 0, 12, 24),
                          children: [
                            Text(
                              'CATEGORIES',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 12),
                            for (var i = 0; i < _categories.length; i++)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: SdtvFocusTile(
                                  label: _categories[i],
                                  autofocus: i == 0,
                                  icon: Icons.folder_outlined,
                                  onActivate: () {
                                    setState(() {
                                      _selectedCategory = i;
                                      _lastAction =
                                          'Category: ${_categories[i]}';
                                      _status =
                                          'Selected category ${_categories[i]}. Move right to channels.';
                                    });
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                      VerticalDivider(
                        width: 1,
                        color: theme.colorScheme.outline.withValues(alpha: 0.3),
                      ),
                      // Channels column
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 24, 24),
                          children: [
                            Text(
                              'CHANNELS · ${_categories[_selectedCategory]}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 12),
                            for (final name in channels)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: SdtvFocusTile(
                                  label: name,
                                  icon: Icons.live_tv_outlined,
                                  onActivate: () {
                                    _setAction(
                                      'Would play: $name (player stub)',
                                    );
                                  },
                                ),
                              ),
                            const SizedBox(height: 24),
                            Text(
                              'TOP BAR',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.outline,
                                letterSpacing: 1.1,
                              ),
                            ),
                            const SizedBox(height: 12),
                            Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                SdtvFocusTile(
                                  label: 'Settings',
                                  icon: Icons.settings_outlined,
                                  onActivate: () =>
                                      _setAction('Open Settings (stub)'),
                                ),
                                SdtvFocusTile(
                                  label: 'About',
                                  icon: Icons.info_outline,
                                  onActivate: () => _showAbout(context),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Footer
              Container(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.25),
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        'Last: $_lastAction',
                        style: theme.textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'js: /dev/input/js*',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'Product of the Wangcow Corporation',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        return SdtvInputScope(
          onBack: () => Navigator.of(ctx).pop(),
          onConfirm: () => Navigator.of(ctx).pop(),
          child: AlertDialog(
            title: const Text('About sdtv'),
            content: const Text(
              'Steam Deck–first IPTV player.\n'
              'Controller playground — Phase 0.\n\n'
              'sdtv is a media player only and does not provide content.\n\n'
              'Product of the Wangcow Corporation\n'
              'Apache License 2.0',
            ),
            actions: [
              SdtvFocusTile(
                label: 'Close',
                autofocus: true,
                onActivate: () => Navigator.of(ctx).pop(),
              ),
            ],
          ),
        );
      },
    );
    _setAction('About opened');
  }
}
