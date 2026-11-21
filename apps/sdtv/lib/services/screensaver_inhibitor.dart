import 'dart:async';
import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

/// Keeps the screensaver away while video plays.
///
/// In Steam Game Mode the session's `org.freedesktop.ScreenSaver` is owned
/// by Steam itself, and Steam's library slideshow otherwise starts behind
/// non-Steam apps during long playback (mpv's own screensaver handling goes
/// through X11 / Wayland, which Steam ignores). The same request works on
/// desktop sessions that provide the service.
abstract class ScreenSaverInhibitor {
  /// True while video is playing (not paused). Idempotent.
  Future<void> setActive(bool active);

  Future<void> dispose();

  /// D-Bus on Linux; does nothing elsewhere and under `flutter test`.
  factory ScreenSaverInhibitor.platform() {
    final test = Platform.environment['FLUTTER_TEST'] == 'true';
    if (!kIsWeb && Platform.isLinux && !test) return DBusScreenSaverInhibitor();
    return NoScreenSaverInhibitor();
  }
}

class NoScreenSaverInhibitor implements ScreenSaverInhibitor {
  @override
  Future<void> setActive(bool active) async {}

  @override
  Future<void> dispose() async {}
}

/// `org.freedesktop.ScreenSaver.Inhibit` / `UnInhibit` on the session bus.
///
/// The connection stays open while inhibited: some implementations drop an
/// inhibit when the caller disconnects. Calls are serialized so quick
/// pause / resume flips cannot leave a stray cookie behind.
class DBusScreenSaverInhibitor implements ScreenSaverInhibitor {
  DBusScreenSaverInhibitor({DBusClient Function()? connect})
    : _connect = connect ?? DBusClient.session;

  /// Opens the bus connection (the session bus; tests use a private bus).
  final DBusClient Function() _connect;
  DBusClient? _client;
  int? _cookie;
  bool _wanted = false;
  bool _unavailable = false;
  Future<void> _queue = Future.value();

  static const _name = 'org.freedesktop.ScreenSaver';
  static final _path = DBusObjectPath('/org/freedesktop/ScreenSaver');

  @override
  Future<void> setActive(bool active) {
    _wanted = active;
    return _queue = _queue.then((_) => _apply()).catchError((Object e) {
      debugPrint('sdtv: screensaver inhibit: $e');
    });
  }

  Future<void> _apply() async {
    if (_unavailable) return;
    if (_wanted && _cookie == null) {
      final client = _client ??= _connect();
      try {
        final reply = await DBusRemoteObject(client, name: _name, path: _path)
            .callMethod(_name, 'Inhibit', [
              const DBusString('sdtv'),
              const DBusString('Playing video'),
            ], replySignature: DBusSignature('u'));
        _cookie = (reply.returnValues.first as DBusUint32).value;
        debugPrint('sdtv: screensaver inhibited (cookie $_cookie)');
      } on DBusMethodResponseException catch (e) {
        // No such service on this session (e.g. some desktops): stop trying.
        _unavailable = true;
        debugPrint('sdtv: screensaver inhibit unavailable: ${e.errorName}');
        await _close();
      }
    } else if (!_wanted && _cookie != null) {
      final cookie = _cookie!;
      _cookie = null;
      final client = _client;
      if (client != null) {
        await DBusRemoteObject(client, name: _name, path: _path).callMethod(
          _name,
          'UnInhibit',
          [DBusUint32(cookie)],
          replySignature: DBusSignature(''),
        );
        debugPrint('sdtv: screensaver allowed again (cookie $cookie)');
      }
      await _close();
    }
  }

  Future<void> _close() async {
    final client = _client;
    _client = null;
    if (client != null) await client.close();
  }

  @override
  Future<void> dispose() async {
    await setActive(false);
    await _close();
  }
}
