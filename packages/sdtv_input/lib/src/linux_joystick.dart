import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// Semantic pad events produced from Linux joystick devices (`/dev/input/js*`).
enum GamepadEdge {
  up,
  down,
  left,
  right,
  confirm,
  back,
  menu,
  /// Y / North — toggle channel favorite.
  favorite,
  /// X / West — mute while watching (optional elsewhere).
  mute,
  pageUp,
  pageDown,
}

/// Linux `struct js_event` reader (8-byte records from `/dev/input/jsN`).
///
/// Uses async `dart:io` reads (IO thread pool) — **no [Isolate]**.
/// Spawning isolates from Flutter Linux was preventing the first frame /
/// window show on Bazzite + NVIDIA when gamepad support was enabled.
class LinuxJoystickReader {
  LinuxJoystickReader({
    this.devicePath,
    /// Hat / D-pad deadzone (axis 6/7). Stick uses [stickDeadzone].
    this.axisDeadzone = 16000,
    /// Left stick needs a larger deadzone — near-center noise during video
    /// playback was spamming channel zap (1↔2 flicker) and starving B.
    this.stickDeadzone = 22000,
    /// Delay before the first auto-repeat (short tap = one step only).
    this.repeatInitial = const Duration(milliseconds: 380),
    /// Base period after [repeatInitial] (then accelerates while held).
    this.repeatPeriod = const Duration(milliseconds: 140),
    /// Auto-repeat only for hat/D-pad (list scroll). Stick is one-shot per tilt
    /// so a resting stick during video never floods channel-up/down.
    this.repeatStick = false,
  });

  final String? devicePath;
  final int axisDeadzone;
  final int stickDeadzone;
  final Duration repeatInitial;
  final Duration repeatPeriod;
  final bool repeatStick;

  RandomAccessFile? _file;
  bool _running = false;
  final _controller = StreamController<GamepadEdge>.broadcast();

  GamepadEdge? _heldDir;
  Timer? _repeatTimer;
  DateTime? _holdStartedAt;
  final Map<int, int> _axisSign = {};
  final Set<int> _buttonsDown = {};

  Stream<GamepadEdge> get events => _controller.stream;

  bool get isOpen => _file != null && _running;

  String? get openPath => _openPath;
  String? _openPath;

  /// Linux joystick button indices vary by driver (xpad vs Steam Deck).
  ///
  /// Common xpad/XInput-ish: 0=A 1=B 2=X 3=Y 4=LB 5=RB 6=Select 7=Start
  /// Deck/Steam often also use 6/7 for View/Options (☰), sometimes 8+ for guide.
  /// Axis: 0=LX 1=LY 6=DpadX 7=DpadY
  static GamepadEdge? mapButton(int number) {
    switch (number) {
      case 0: // A / South
        return GamepadEdge.confirm;
      case 1: // B / East
        return GamepadEdge.back;
      case 2: // X / West — mute in player
        return GamepadEdge.mute;
      case 3: // Y / North — favorite (Start/Select still open menu)
        return GamepadEdge.favorite;
      case 4: // LB
        return GamepadEdge.pageUp;
      case 5: // RB
        return GamepadEdge.pageDown;
      case 6: // Select / View (…) — treat as menu, NOT back
        return GamepadEdge.menu;
      case 7: // Start / Options (☰)
        return GamepadEdge.menu;
      case 8: // Guide / mode on some stacks
      case 9:
      case 10:
      case 11:
        return GamepadEdge.menu;
      default:
        return null;
    }
  }

  /// Enumerate `/dev/input/js*` (hotplug-safe; not limited to js0–js3).
  static List<String> listDevicePaths({int maxIndex = 15}) {
    final out = <String>[];
    try {
      final dir = Directory('/dev/input');
      if (dir.existsSync()) {
        for (final ent in dir.listSync(followLinks: true)) {
          final base = ent.path.split('/').last;
          if (RegExp(r'^js\d+$').hasMatch(base)) {
            out.add(ent.path);
          }
        }
      }
    } catch (_) {}
    if (out.isEmpty) {
      for (var i = 0; i <= maxIndex; i++) {
        final p = '/dev/input/js$i';
        try {
          if (File(p).existsSync()) out.add(p);
        } catch (_) {}
      }
    }
    out.sort((a, b) {
      int n(String p) {
        final m = RegExp(r'js(\d+)$').firstMatch(p);
        return int.tryParse(m?.group(1) ?? '') ?? 0;
      }

      return n(a).compareTo(n(b));
    });
    return out;
  }

  /// Open a single device ([devicePath]) or the first available joystick.
  Future<bool> open() async {
    await close();

    final candidates = <String>[
      if (devicePath != null) devicePath!,
      if (devicePath == null) ...listDevicePaths(),
    ];

    for (final path in candidates) {
      try {
        final f = await File(path).open(mode: FileMode.read);
        _file = f;
        _openPath = path;
        _running = true;
        // Fire-and-forget pump; IO waits on the background thread pool.
        unawaited(_pump());
        return true;
      } on FileSystemException {
        continue;
      } on PathNotFoundException {
        continue;
      } catch (_) {
        continue;
      }
    }
    return false;
  }

  Future<void> _pump() async {
    final file = _file;
    if (file == null) return;

    while (_running && identical(_file, file)) {
      try {
        final bytes = await file.read(8);
        if (!_running) break;
        if (bytes.length == 8) {
          _handleFrame(Uint8List.fromList(bytes));
        } else if (bytes.isEmpty) {
          // EOF / unplug
          break;
        }
      } on FileSystemException {
        break;
      } catch (_) {
        break;
      }
    }
    await close();
  }

  void _handleFrame(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final value = data.getInt16(4, Endian.little);
    final type = data.getUint8(6);
    final number = data.getUint8(7);

    const jsEventButton = 0x01;
    const jsEventAxis = 0x02;
    const jsEventInit = 0x80;

    final kind = type & ~jsEventInit;
    final isInit = (type & jsEventInit) != 0;

    if (kind == jsEventButton) {
      final pressed = value != 0;
      if (pressed) {
        if (_buttonsDown.add(number) && !isInit) {
          // Cancel stick/hat hold so B is not drowned by direction spam.
          _heldDir = null;
          _repeatTimer?.cancel();
          _repeatTimer = null;
          final edge = mapButton(number);
          if (edge != null) {
            debugPrint('sdtv_input: js button $number → $edge');
            _emit(edge);
          } else {
            debugPrint('sdtv_input: js button $number (unmapped)');
          }
        }
      } else {
        _buttonsDown.remove(number);
      }
      return;
    }

    if (kind == jsEventAxis) {
      final isStick = number == 0 || number == 1;
      final isHat = number == 6 || number == 7;
      if (!isStick && !isHat) return;

      final sign = _signForAxis(value, stick: isStick);
      final prev = _axisSign[number] ?? 0;
      if (sign == prev) return;
      _axisSign[number] = sign;
      if (isInit) return;

      if (number == 0 || number == 6) {
        if (sign < 0) {
          _setHeldDir(GamepadEdge.left, allowRepeat: isHat || repeatStick);
        } else if (sign > 0) {
          _setHeldDir(GamepadEdge.right, allowRepeat: isHat || repeatStick);
        } else {
          _clearHeldIfAxis(xAxis: true);
        }
      } else if (number == 1 || number == 7) {
        if (sign < 0) {
          _setHeldDir(GamepadEdge.up, allowRepeat: isHat || repeatStick);
        } else if (sign > 0) {
          _setHeldDir(GamepadEdge.down, allowRepeat: isHat || repeatStick);
        } else {
          _clearHeldIfAxis(xAxis: false);
        }
      }
    }
  }

  int _signForAxis(int value, {required bool stick}) {
    final dz = stick ? stickDeadzone : axisDeadzone;
    if (value > dz) return 1;
    if (value < -dz) return -1;
    return 0;
  }

  void _setHeldDir(GamepadEdge dir, {required bool allowRepeat}) {
    if (_heldDir == dir) return;
    _heldDir = dir;
    _holdStartedAt = DateTime.now();
    _emit(dir);
    _repeatTimer?.cancel();
    _repeatTimer = null;
    if (!allowRepeat) return;
    // First repeat after [repeatInitial], then accelerate while held.
    _repeatTimer = Timer(repeatInitial, _onRepeatTick);
  }

  void _onRepeatTick() {
    final dir = _heldDir;
    final started = _holdStartedAt;
    if (dir == null || started == null) {
      _repeatTimer = null;
      return;
    }
    final heldMs = DateTime.now().difference(started).inMilliseconds;
    // One step per tick; period shortens while held (see [_acceleratedPeriod]).
    // Multi-step bursts fight UI cooldowns and only one row would move.
    _emit(dir);
    _repeatTimer = Timer(_acceleratedPeriod(heldMs), _onRepeatTick);
  }

  /// Faster repeat the longer the D-pad is held (~7 → ~25 rows/sec).
  Duration _acceleratedPeriod(int heldMs) {
    if (heldMs < 900) return repeatPeriod; // ~140ms
    if (heldMs < 1500) return const Duration(milliseconds: 80);
    if (heldMs < 2200) return const Duration(milliseconds: 50);
    return const Duration(milliseconds: 32);
  }

  void _clearHeldIfAxis({required bool xAxis}) {
    final held = _heldDir;
    if (held == null) return;
    final isX = held == GamepadEdge.left || held == GamepadEdge.right;
    final isY = held == GamepadEdge.up || held == GamepadEdge.down;
    if ((xAxis && isX) || (!xAxis && isY)) {
      final otherHeld = xAxis
          ? (_axisSign[1] ?? 0) != 0 || (_axisSign[7] ?? 0) != 0
          : (_axisSign[0] ?? 0) != 0 || (_axisSign[6] ?? 0) != 0;
      if (!otherHeld) {
        _heldDir = null;
        _holdStartedAt = null;
        _repeatTimer?.cancel();
        _repeatTimer = null;
      } else if (xAxis) {
        final yStick = _axisSign[1] ?? 0;
        final yHat = _axisSign[7] ?? 0;
        final y = yStick != 0 ? yStick : yHat;
        final yIsHat = yStick == 0 && yHat != 0;
        if (y < 0) {
          _setHeldDir(GamepadEdge.up, allowRepeat: yIsHat || repeatStick);
        } else if (y > 0) {
          _setHeldDir(GamepadEdge.down, allowRepeat: yIsHat || repeatStick);
        }
      } else {
        final xStick = _axisSign[0] ?? 0;
        final xHat = _axisSign[6] ?? 0;
        final x = xStick != 0 ? xStick : xHat;
        final xIsHat = xStick == 0 && xHat != 0;
        if (x < 0) {
          _setHeldDir(GamepadEdge.left, allowRepeat: xIsHat || repeatStick);
        } else if (x > 0) {
          _setHeldDir(GamepadEdge.right, allowRepeat: xIsHat || repeatStick);
        }
      }
    }
  }

  void _emit(GamepadEdge edge) {
    if (!_controller.isClosed) _controller.add(edge);
  }

  Future<void> close() async {
    _running = false;
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _heldDir = null;
    _holdStartedAt = null;
    _axisSign.clear();
    _buttonsDown.clear();
    final f = _file;
    _file = null;
    _openPath = null;
    try {
      await f?.close();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await close();
    await _controller.close();
  }
}
