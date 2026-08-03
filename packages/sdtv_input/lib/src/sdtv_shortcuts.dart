import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'actions.dart';
import 'gamepad_focus_binding.dart';
import 'input_callbacks.dart';

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

/// Keyboard / OSK shortcuts. Prefer [NextFocusIntent] for Tab (forms).
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

    // Tab must be NextFocus — Deck OSK Tab is useless otherwise.
    const SingleActivator(LogicalKeyboardKey.tab): const NextFocusIntent(),
    const SingleActivator(LogicalKeyboardKey.tab, shift: true):
        const PreviousFocusIntent(),

    const SingleActivator(LogicalKeyboardKey.enter): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter):
        const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.select): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.space): const SdtvConfirmIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonA):
        const SdtvConfirmIntent(),

    // NOTE: Escape → Back. Some Steam layouts also emit Escape for ☰;
    // browse page uses a system menu so that is still recoverable.
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
    const SingleActivator(LogicalKeyboardKey.gameButtonMode):
        const SdtvMenuIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonY):
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

Map<Type, Action<Intent>> sdtvDefaultActions({
  VoidCallback? onConfirm,
  VoidCallback? onBack,
  VoidCallback? onMenu,
}) {
  return <Type, Action<Intent>>{
    DirectionalFocusIntent: DirectionalFocusAction(),
    NextFocusIntent: CallbackAction<NextFocusIntent>(
      onInvoke: (_) {
        FocusManager.instance.primaryFocus?.nextFocus();
        return null;
      },
    ),
    PreviousFocusIntent: CallbackAction<PreviousFocusIntent>(
      onInvoke: (_) {
        FocusManager.instance.primaryFocus?.previousFocus();
        return null;
      },
    ),
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

/// Wraps [child] with sdtv shortcuts, actions, callbacks, and gamepad binding.
class SdtvInputScope extends StatelessWidget {
  const SdtvInputScope({
    super.key,
    required this.child,
    this.onConfirm,
    this.onBack,
    this.onMenu,
    this.extraShortcuts = const {},
    this.extraActions = const {},
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
    return SdtvInputCallbacks(
      onConfirm: onConfirm,
      onBack: onBack,
      onMenu: onMenu,
      child: Shortcuts(
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
      ),
    );
  }
}
