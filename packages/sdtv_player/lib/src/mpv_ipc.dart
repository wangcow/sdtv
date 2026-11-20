import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One long-lived JSON IPC connection to an mpv `--input-ipc-server` socket.
///
/// Replies are matched by `request_id`, so callers can overlap requests.
/// Lines without a `request_id` reply (events, `property-change`) go to
/// [events].
class MpvIpcConnection {
  MpvIpcConnection._(this._socket) {
    _sub = _socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onError: (Object _) => _shutdown(), onDone: _shutdown);
  }

  /// Connects to the unix socket at [path]. Null when mpv is not listening.
  static Future<MpvIpcConnection?> connect(
    String path, {
    Duration timeout = const Duration(milliseconds: 500),
  }) async {
    try {
      final addr = InternetAddress(path, type: InternetAddressType.unix);
      final socket = await Socket.connect(addr, 0).timeout(timeout);
      return MpvIpcConnection._(socket);
    } catch (_) {
      return null;
    }
  }

  final Socket _socket;
  late final StreamSubscription<String> _sub;
  final Map<int, Completer<Map<String, dynamic>?>> _pending = {};
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();
  int _nextId = 1;
  bool _closed = false;

  bool get isClosed => _closed;

  /// mpv events (`property-change`, `end-file`, …).
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// Sends [command] (a positional list or a named-argument map).
  ///
  /// Returns mpv's reply, or null when the connection is gone or no reply
  /// arrives within [timeout].
  Future<Map<String, dynamic>?> request(
    Object command, {
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    if (_closed) return null;
    final id = _nextId++;
    final done = Completer<Map<String, dynamic>?>();
    _pending[id] = done;
    try {
      _socket.write('${jsonEncode({'command': command, 'request_id': id})}\n');
    } catch (_) {
      _pending.remove(id);
      _shutdown();
      return null;
    }
    try {
      return await done.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      _pending.remove(id);
    }
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final map = Map<String, dynamic>.from(decoded);
    if (map.containsKey('event')) {
      if (!_events.isClosed) _events.add(map);
      return;
    }
    final id = map['request_id'];
    final waiter = id is int ? _pending.remove(id) : null;
    if (waiter != null && !waiter.isCompleted) waiter.complete(map);
  }

  void _shutdown() {
    if (_closed) return;
    _closed = true;
    for (final w in _pending.values) {
      if (!w.isCompleted) w.complete(null);
    }
    _pending.clear();
    unawaited(_sub.cancel());
    unawaited(_events.close());
    try {
      _socket.destroy();
    } catch (e) {
      debugPrint('sdtv_player: ipc close: $e');
    }
  }

  Future<void> close() async => _shutdown();
}
