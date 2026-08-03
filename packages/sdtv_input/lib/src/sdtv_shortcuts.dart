import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'actions.dart';
import 'gamepad_focus_binding.dart';

/// True when we should open `/dev/input/js*`.
///
/// On by default for Linux. Disable with `SDTV_ENABLE_GAMEPAD=0`.
bool sdtvGamepadBindingEnabledByDefault() {
  if (kIsWeb) return false;
  if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
  final flag = Platform.environment['SDTV_ENABLE_GAMEPAD']?.toLowerCase();
  if (flag == '0' || flag == 'false' || flag == 'no') return false;
  try {
    return Platform.isLinux;
  } catch (_) {
    return false;
  }
}

/// Keyboard / TV-remote style shortcuts that mirror gamepad intents.
///
/// Arrow keys always work for desktop dev. `LogicalKeyboardKey.gameButton*`
/// only fires if something synthesizes key events (rare for raw USB pads).
/// Real controllers on Linux are handled by [SdtvGamepadBinding].
Map<ShortcutActivator, Intent> sdtvNavigationShortcuts() {
  return <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.arrowUp):
        const DirectionalFocusIntent(TraversalDirection.up),
    const SingleActivator(LogicalKeyboardKey.arrowDown):
        const DirectionalFocusIntent(TraversalDirection.down),
    const SingleActivator(LogicalKeyboardKey.arrowLeft):
        const DirectionalFocusIntent(TraversalDirection.left),
    const SingleActivator(LogicalKeyboardKey.arrowRight):
        const DirectionalFocusIntent(TraversalDirection.right),

    const SingleActivator(LogicalKeyboardKey.enter): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter):
        const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.select): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.space): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonA):
        const SdtvConfirmIntent(),

    const SingleActivator(LogicalKeyboardKey.escape): const SdtvBackIntent(),
    const SingleActivator(LogicalKeyboardKey.goBack): const SdtvBackIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonB):
        const SdtvBackIntent(),
    const SingleActivator(LogicalKeyboardKey.browserBack):
        const SdtvBackIntent(),

    const SingleActivator(LogicalKeyboardKey.contextMenu):
        const SdtvMenuIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonStart):
        const SdtvMenuIntent(),
    // Some Deck/Steam layouts emit these for Options (☰).
    const SingleActivator(LogicalKeyboardKey.gameButtonMode):
        const SdtvMenuIntent(),
    const SingleActivator(LogicalKeyboardKey.f1): const SdtvMenuIntent(),

    const SingleActivator(LogicalKeyboardKey.gameButtonLeft1):
        const SdtvPageUpIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonRight1):
        const SdtvPageDownIntent(),
    const SingleActivator(LogicalKeyboardKey.pageUp): const SdtvPageUpIntent(),
    const SingleActivator(LogicalKeyboardKey.pageDown):
        const SdtvPageDownIntent(),
  };
}

/// Default [Actions] map for common sdtv intents.
Map<Type, Action<Intent>> sdtvDefaultActions({
  VoidCallback? onConfirm,
  VoidCallback? onBack,
  VoidCallback? onMenu,
}) {
  return <Type, Action<Intent>>{
    DirectionalFocusIntent: DirectionalFocusAction(),
    ActivateIntent: CallbackAction<ActivateIntent>(
      onInvoke: (_) {
        onConfirm?.call();
        return null;
      },
    ),
    SdtvConfirmIntent: CallbackAction<SdtvConfirmIntent>(
      onInvoke: (_) {
        onConfirm?.call();
        return null;
      },
    ),
    SdtvBackIntent: CallbackAction<SdtvBackIntent>(
      onInvoke: (_) {
        onBack?.call();
        return null;
      },
    ),
    SdtvMenuIntent: CallbackAction<SdtvMenuIntent>(
      onInvoke: (_) {
        onMenu?.call();
        return null;
      },
    ),
    SdtvPageUpIntent: CallbackAction<SdtvPageUpIntent>(
      onInvoke: (_) => null,
    ),
    SdtvPageDownIntent: CallbackAction<SdtvPageDownIntent>(
      onInvoke: (_) => null,
    ),
  };
}

/// Wraps [child] with sdtv [Shortcuts] + [Actions] + Linux gamepad binding.
class SdtvInputScope extends StatelessWidget {
  const SdtvInputScope({
    super.key,
    required this.child,
    this.onConfirm,
    this.onBack,
    this.onMenu,
    this.extraShortcuts = const {},
    this.extraActions = const {},
    /// `null` = auto (Linux, not under `flutter test`).
    this.enableGamepad,
  });

  final Widget child;
  final VoidCallback? onConfirm;
  final VoidCallback? onBack;
  final VoidCallback? onMenu;
  final Map<ShortcutActivator, Intent> extraShortcuts;
  final Map<Type, Action<Intent>> extraActions;
  final bool? enableGamepad;

  @override
  Widget build(BuildContext context) {
    final padOn = enableGamepad ?? sdtvGamepadBindingEnabledByDefault();
    return Shortcuts(
      shortcuts: {
        ...sdtvNavigationShortcuts(),
        ...extraShortcuts,
      },
      child: Actions(
        actions: {
          ...sdtvDefaultActions(
            onConfirm: onConfirm,
            onBack: onBack,
            onMenu: onMenu,
          ),
          ...extraActions,
        },
        child: SdtvGamepadBinding(
          enabled: padOn,
          child: child,
        ),
      ),
    );
  }
}
