import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

/// Result of a fullscreen external [mpv] session.
class ExternalMpvResult {
  const ExternalMpvResult({
    required this.started,
    this.exitCode,
    this.error,
    this.mpvPath,
    this.busy = false,
    this.durationMs,
    this.userQuit = false,
  });

  final bool started;
  final int? exitCode;
  final String? error;
  final String? mpvPath;

  /// True when a session was already in flight (re-entry ignored).
  final bool busy;

  /// Wall time from spawn to process exit (null if never started).
  final int? durationMs;

  /// True when we called [quit]/[stop] (B / menu), not a spontaneous crash.
  final bool userQuit;

  bool get ok => started && error == null && !busy;

  /// Process died quickly without a user quit — often a bad stream URL.
  bool get failedFast =>
      started &&
      !busy &&
      !userQuit &&
      durationMs != null &&
      durationMs! < 4500;
}

/// How to invoke mpv (native binary vs Flatpak app).
class _MpvInvoke {
  const _MpvInvoke.binary(this.executable) : appId = null;

  const _MpvInvoke.flatpak(this.appId) : executable = 'flatpak';

  final String executable;
  final String? appId;

  bool get isFlatpak => appId != null;

  String get label => isFlatpak ? 'flatpak:$appId' : executable;
}

/// Spawns system/bundled **mpv** fullscreen for a single URL and waits until exit.
///
/// Phase A handoff: Flutter keeps the guide; mpv owns the picture.
/// Couch control while watching: [quit] / [cyclePause] via JSON IPC (Flutter still
/// reads `/dev/input/js*` under the fullscreen child).
class ExternalMpvLauncher {
  ExternalMpvLauncher({this.extraArgs = const []});

  /// Extra CLI flags (e.g. from env later).
  final List<String> extraArgs;

  Process? _process;

  /// True only while finding binary / Process.start (not for the whole play).
  bool _launching = false;

  String? _ipcPath;

  bool _userQuit = false;

  /// Quit + re-spawn mpv only when the **nest** pixel size actually changes.
  bool _restartForDisplay = false;

  /// True for the whole watch session (including brief gap during respawn).
  bool _sessionActive = false;

  /// Current stream (updated on zap) — used when respawning after dock.
  Uri? _activeUrl;
  String? _activeTitle;
  Uri? _activeFallback;
  String? _activeFallbackTitle;

  /// Recent mpv log lines (for HTTP 403-style error messages).
  final List<String> _recentLog = <String>[];

  /// Dock / display-size watch while fullscreen (handheld → TV).
  Timer? _displayWatch;
  Timer? _restartDebounce;
  int? _targetW;
  int? _targetH;
  /// Size when this mpv process started (detect real nest resize).
  int? _processStartW;
  int? _processStartH;
  DateTime? _lastRestartAt;
  bool _dockHintShown = false;

  /// Gamescope kept the handheld nest after docking (TV is larger).
  /// Only a **full sdtv relaunch** from Steam gets Native 1080p.
  bool needsAppRestartForFullDisplay = false;

  bool get isRunning =>
      _process != null || _launching || _sessionActive;

  /// Steam / host noise — not a stream failure (common on Deck Game Mode).
  static bool _isNoiseLogLine(String line) {
    final lower = line.toLowerCase();
    return lower.contains('ld.so') ||
        lower.contains('gameoverlay') ||
        lower.contains('gameoverlayrenderer') ||
        lower.contains('cannot be preloaded') ||
        lower.contains('steamoverlay') ||
        lower.contains('pressure-vessel') ||
        lower.contains('libsteam') ||
        // Harmless mpv chatter
        lower.contains('ao/pulse') && lower.contains('broken pipe');
  }

  void _noteLog(String line) {
    final t = line.trim();
    if (t.isEmpty || _isNoiseLogLine(t)) return;
    _recentLog.add(t);
    if (_recentLog.length > 40) {
      _recentLog.removeRange(0, _recentLog.length - 40);
    }
  }

  void clearRecentLog() => _recentLog.clear();

  /// True when logs look like a real stream/network failure (not Steam noise).
  bool get hasMeaningfulStreamError {
    final blob = _recentLog.join('\n').toLowerCase();
    if (blob.isEmpty) return false;
    return RegExp(
      r'\b403\b|\b401\b|\b404\b|\b502\b|\b503\b|\b504\b|'
      r'forbidden|unauthorized|timed out|timeout|'
      r'connection refused|network is unreachable|no route to host|'
      r'failed to open|failed to recognize|error opening|opening failed|'
      r'http error|ssl|certificate|no decoder',
    ).hasMatch(blob);
  }

  /// Best-effort human error from mpv logs (TiviMate-style).
  String playbackErrorHint({String? channelName}) {
    final blob = _recentLog.join('\n').toLowerCase();
    String core;
    if (RegExp(r'\b403\b|http error 403|forbidden').hasMatch(blob)) {
      core = 'HTTP 403 Forbidden';
    } else if (RegExp(r'\b401\b|unauthorized').hasMatch(blob)) {
      core = 'HTTP 401 Unauthorized';
    } else if (RegExp(r'\b404\b|not found').hasMatch(blob)) {
      core = 'HTTP 404 Not Found';
    } else if (RegExp(r'\b502\b|\b503\b|\b504\b').hasMatch(blob)) {
      core = 'Server error (5xx)';
    } else if (blob.contains('ssl') || blob.contains('certificate')) {
      core = 'TLS/SSL error';
    } else if (blob.contains('timed out') || blob.contains('timeout')) {
      core = 'Connection timed out';
    } else if (blob.contains('connection refused') ||
        blob.contains('network is unreachable') ||
        blob.contains('no route to host')) {
      core = 'Network error';
    } else if (blob.contains('failed to recognize file format') ||
        blob.contains('failed to open') ||
        blob.contains('error opening') ||
        blob.contains('opening failed')) {
      core = 'Failed to open stream';
    } else if (blob.contains('no decoder') ||
        (blob.contains('codec') && blob.contains('error'))) {
      core = 'Codec / decode error';
    } else {
      core = 'Playback failed';
    }

    // Last meaningful log line for detail (truncated) — skip Steam/ld.so noise.
    String? detail;
    for (var i = _recentLog.length - 1; i >= 0; i--) {
      final line = _recentLog[i];
      if (_isNoiseLogLine(line)) continue;
      final lower = line.toLowerCase();
      if (lower.contains('http') ||
          lower.contains('error') ||
          lower.contains('failed') ||
          lower.contains('forbidden') ||
          RegExp(r'\b[45]\d\d\b').hasMatch(lower)) {
        detail = line.length > 90 ? '${line.substring(0, 87)}…' : line;
        break;
      }
    }

    final name = (channelName != null && channelName.trim().isNotEmpty)
        ? channelName.trim()
        : null;
    final buf = StringBuffer(core);
    if (name != null) buf.write('\n$name');
    if (detail != null && !detail.toLowerCase().contains(core.toLowerCase())) {
      buf.write('\n$detail');
    }
    buf.write('\nB guide · LB/RB other channel');
    return buf.toString();
  }

  /// Show a multi-line playback error on the OSD.
  Future<void> showPlaybackError({String? channelName}) async {
    await showText(
      playbackErrorHint(channelName: channelName),
      durationMs: 5000,
    );
  }

  /// Common Flatpak app IDs for mpv (Discover / Flathub).
  static const flatpakAppIds = <String>[
    'io.mpv.Mpv',
    'org.mpv.Mpv',
  ];

  /// Locate an mpv binary or Flatpak app.
  static Future<_MpvInvoke?> _findMpv() async {
    final env = Platform.environment['SDTV_MPV_PATH'];
    if (env != null && env.isNotEmpty) {
      if (env.startsWith('flatpak:')) {
        return _MpvInvoke.flatpak(env.substring('flatpak:'.length));
      }
      if (flatpakAppIds.contains(env)) {
        return _MpvInvoke.flatpak(env);
      }
      if (await File(env).exists()) {
        return _MpvInvoke.binary(env);
      }
    }

    final home = Platform.environment['HOME'];
    final candidates = <String>[
      _besideExecutable('mpv'),
      '/usr/bin/mpv',
      '/usr/local/bin/mpv',
      '/bin/mpv',
      if (home != null) '$home/.local/bin/mpv',
    ];

    for (final id in flatpakAppIds) {
      candidates.add('/var/lib/flatpak/exports/bin/$id');
      if (home != null) {
        candidates.add('$home/.local/share/flatpak/exports/bin/$id');
      }
    }

    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(':')) {
      if (dir.isEmpty) continue;
      candidates.add('$dir/mpv');
      for (final id in flatpakAppIds) {
        candidates.add('$dir/$id');
      }
    }

    if (home != null) {
      candidates.add('$home/.linuxbrew/bin/mpv');
    }
    candidates.add('/home/linuxbrew/.linuxbrew/bin/mpv');

    final seen = <String>{};
    for (final c in candidates) {
      if (c.isEmpty || !seen.add(c)) continue;
      try {
        if (!await File(c).exists()) continue;
        final base = c.split('/').last;
        if (flatpakAppIds.contains(base)) {
          return _MpvInvoke.flatpak(base);
        }
        return _MpvInvoke.binary(c);
      } catch (_) {}
    }

    try {
      final r = await Process.run('sh', ['-c', 'command -v mpv']);
      if (r.exitCode == 0) {
        final p = (r.stdout as String).trim().split('\n').first.trim();
        if (p.isNotEmpty && await File(p).exists()) {
          return _MpvInvoke.binary(p);
        }
      }
    } catch (_) {}

    for (final id in flatpakAppIds) {
      try {
        final r = await Process.run('flatpak', ['info', id]);
        if (r.exitCode == 0) {
          return _MpvInvoke.flatpak(id);
        }
      } catch (_) {}
    }

    return null;
  }

  /// Path/label for diagnostics.
  static Future<String?> findMpvBinary() async {
    final inv = await _findMpv();
    return inv?.label;
  }

  static String _besideExecutable(String name) {
    try {
      final exe = Platform.resolvedExecutable;
      final dir = File(exe).parent.path;
      return '$dir/$name';
    } catch (_) {
      return name;
    }
  }

  /// Keep VAAPI hints; drop brew LD_LIBRARY_PATH so host/Flatpak mpv is clean.
  ///
  /// Also strip Steam Overlay [LD_PRELOAD] (gameoverlayrenderer) — Deck Game
  /// Mode injects it into Non-Steam games; the linker warning is harmless but
  /// was being parsed as a stream failure ("Playback failed … ld.so object…").
  static Map<String, String> _childEnvironment() {
    final env = Map<String, String>.from(Platform.environment);
    env['LD_LIBRARY_PATH'] = '/usr/lib64:/usr/lib';

    final preload = env['LD_PRELOAD'];
    if (preload != null && preload.isNotEmpty) {
      final cleaned = preload
          .split(RegExp(r'[:\s]+'))
          .where((p) => p.isNotEmpty)
          .where((p) {
            final l = p.toLowerCase();
            return !l.contains('gameoverlay') &&
                !l.contains('steamoverlay') &&
                !l.contains('libsteam');
          })
          .join(':');
      if (cleaned.isEmpty) {
        env.remove('LD_PRELOAD');
      } else {
        env['LD_PRELOAD'] = cleaned;
      }
    }

    if (Platform.environment['LIBVA_DRIVERS_PATH'] != null) {
      env['LIBVA_DRIVERS_PATH'] = Platform.environment['LIBVA_DRIVERS_PATH']!;
    } else if (Directory('/usr/lib64/dri').existsSync()) {
      env['LIBVA_DRIVERS_PATH'] = '/usr/lib64/dri';
    } else if (Directory('/usr/lib/dri').existsSync()) {
      env['LIBVA_DRIVERS_PATH'] = '/usr/lib/dri';
    }
    if (Platform.environment['LIBVA_DRIVER_NAME'] != null) {
      env['LIBVA_DRIVER_NAME'] = Platform.environment['LIBVA_DRIVER_NAME']!;
    }
    return env;
  }

  String _newIpcPath() {
    final n = Random().nextInt(0x7fffffff);
    return '/tmp/sdtv-mpv-$n.sock';
  }

  int _ipcReqId = 1;

  /// Send a JSON IPC command; waits for mpv's reply when possible.
  ///
  /// Returns false on transport failure or non-success error from mpv.
  Future<bool> sendCommand(List<Object?> command) async {
    final res = await _ipc(command);
    return res != null && res['error'] == 'success';
  }

  /// Low-level IPC: returns decoded JSON reply, or null on failure.
  Future<Map<String, dynamic>?> _ipc(List<Object?> command) async {
    final path = _ipcPath;
    if (path == null || !isRunning) return null;
    final id = _ipcReqId++;
    try {
      final addr = InternetAddress(path, type: InternetAddressType.unix);
      final socket = await Socket.connect(addr, 0)
          .timeout(const Duration(milliseconds: 500));
      final payload = jsonEncode({
        'command': command,
        'request_id': id,
      });
      socket.write('$payload\n');
      await socket.flush().timeout(const Duration(milliseconds: 500));

      // mpv may emit events; read until our request_id matches.
      final lines = socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      Map<String, dynamic>? matched;
      await for (final line in lines.timeout(
        const Duration(milliseconds: 800),
        onTimeout: (sink) => sink.close(),
      )) {
        if (line.trim().isEmpty) continue;
        try {
          final map = jsonDecode(line);
          if (map is Map<String, dynamic>) {
            if (map['request_id'] == id ||
                (map['error'] != null && map['event'] == null)) {
              matched = map;
              break;
            }
          } else if (map is Map) {
            final m = Map<String, dynamic>.from(map);
            if (m['request_id'] == id) {
              matched = m;
              break;
            }
          }
        } catch (_) {}
      }
      try {
        await socket.close();
      } catch (_) {}

      if (matched == null) {
        debugPrint('sdtv_player: mpv ipc no reply for $command');
        // Write may still have worked (mute/volume often do).
        return {'error': 'success', 'data': null, 'assumed': true};
      }
      if (matched['error'] != null && matched['error'] != 'success') {
        debugPrint(
          'sdtv_player: mpv ipc error ${matched['error']} for $command',
        );
      }
      return matched;
    } catch (e) {
      debugPrint('sdtv_player: mpv ipc failed ($command): $e');
      return null;
    }
  }

  Future<Object?> getProperty(String name) async {
    final res = await _ipc(['get_property', name]);
    if (res == null || res['error'] != 'success') return null;
    return res['data'];
  }

  /// Pause / unpause via IPC. Prefer [setPaused] when driving a watch menu.
  Future<void> cyclePause() async {
    await sendCommand(['cycle', 'pause']);
  }

  Future<void> setPaused(bool paused) async {
    await sendCommand(['set', 'pause', paused ? 'yes' : 'no']);
  }

  Future<bool> isPaused() async {
    final p = await getProperty('pause');
    return p == true || p == 'yes';
  }

  /// Resume live IPTV at the **current edge** (not mid old buffer).
  ///
  /// After pause, HLS/TS windows slide; unpause alone often replays an older
  /// segment (or a different program's audio in the mux). Reloading [path]
  /// matches "go back to live" behavior.
  Future<void> resumeLiveEdge({String? title}) async {
    Uri? url = _activeUrl;
    if (url == null) {
      final path = await getProperty('path');
      if (path != null && '$path'.isNotEmpty && path != false) {
        url = Uri.tryParse('$path');
      }
    }
    if (url != null) {
      final t = (title != null && title.trim().isNotEmpty)
          ? title.trim()
          : _activeTitle;
      await loadFile(url, title: t);
    }
    await setPaused(false);
    await setOscVisible(false);
  }

  Future<void> setOscVisible(bool always) async {
    // External live sessions run with --osc=no; keep IPC harmless if OSC absent.
    await sendCommand([
      'script-message',
      'osc-visibility',
      always ? 'always' : 'never',
      'no-osd',
    ]);
  }

  /// Set the window / OSC title (channel name).
  Future<void> setMediaTitle(String title) async {
    final t = title.trim();
    if (t.isEmpty) return;
    await sendCommand(['set', 'force-media-title', t]);
  }

  /// Cycle subtitle track (includes “no” / Off — intentional for subs).
  Future<void> cycleSubtitleTrack() async {
    await sendCommand(['cycle', 'sid']);
  }

  /// Cycle **audio** among real tracks only.
  ///
  /// Never leaves [aid]=no: mpv's plain `cycle aid` includes "no", and on many
  /// live streams returning from "no" does not restore sound until reload.
  /// Mute is a separate control ([cycleMute]).
  Future<void> cycleAudioTrack({int direction = 1}) async {
    final ids = await _trackIds('audio');
    if (ids.isEmpty) {
      // No track-list (or empty) — try soft recover then bail.
      await ensureAudioOn();
      return;
    }

    final current = await getProperty('aid');
    final curKey = _trackIdKey(current);
    var idx = ids.indexWhere((id) => _trackIdKey(id) == curKey);

    if (ids.length == 1) {
      // Single track: re-select it (recovers from accidental aid=no).
      await sendCommand(['set', 'aid', ids.first]);
      await sendCommand(['set', 'mute', 'no']);
      return;
    }

    if (idx < 0) {
      // Off or unknown → first track.
      idx = 0;
    } else {
      idx = (idx + direction) % ids.length;
      if (idx < 0) idx += ids.length;
    }
    await sendCommand(['set', 'aid', ids[idx]]);
    // Ensure we didn't mute earlier while "off".
    await sendCommand(['set', 'mute', 'no']);
  }

  /// If audio is disabled (aid=no), select the first audio track again.
  Future<void> ensureAudioOn() async {
    final aid = await getProperty('aid');
    if (aid != false && aid != 'no' && aid != null) return;
    final ids = await _trackIds('audio');
    if (ids.isNotEmpty) {
      await sendCommand(['set', 'aid', ids.first]);
    } else {
      await sendCommand(['set', 'aid', 'auto']);
      await sendCommand(['cycle', 'aid']);
    }
    await sendCommand(['set', 'mute', 'no']);
  }

  Future<List<Object>> _trackIds(String type) async {
    final raw = await getProperty('track-list');
    if (raw is! List) return const [];
    final ids = <Object>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final map = Map<Object?, Object?>.from(item);
      if ('${map['type']}' != type) continue;
      // Skip external-only weirdness; require an id.
      final id = map['id'];
      if (id == null) continue;
      ids.add(id);
    }
    return ids;
  }

  static String _trackIdKey(Object? id) {
    if (id == null || id == false) return 'no';
    return '$id';
  }

  Future<void> cycleSubVisibility() async {
    await sendCommand(['cycle', 'sub-visibility']);
  }

  /// Human label for current subtitles (best-effort).
  Future<String> subtitleLabel() async {
    final sid = await getProperty('sid');
    if (sid == false || sid == 'no' || sid == null) return 'Off';
    final vis = await getProperty('sub-visibility');
    if (vis == false || vis == 'no') return 'Hidden';
    final title = await getProperty('current-tracks/sub/title');
    final lang = await getProperty('current-tracks/sub/lang');
    if (title is String && title.trim().isNotEmpty) return title.trim();
    if (lang is String && lang.trim().isNotEmpty) return lang.trim();
    return 'Track $sid';
  }

  Future<String> audioLabel() async {
    final aid = await getProperty('aid');
    if (aid == false || aid == 'no' || aid == null) return 'Off (fixing…)';
    final title = await getProperty('current-tracks/audio/title');
    final lang = await getProperty('current-tracks/audio/lang');
    if (title is String && title.trim().isNotEmpty) return title.trim();
    if (lang is String && lang.trim().isNotEmpty) return lang.trim();
    return 'Track $aid';
  }

  /// Relative volume change with OSD bar + numeric readout.
  Future<void> addVolume(int delta) async {
    // osd-msg-bar shows the volume slider; plain add is silent on some builds.
    var ok = await sendCommand(['osd-msg-bar', 'add', 'volume', delta]);
    if (!ok) {
      ok = await sendCommand(['add', 'volume', delta]);
    }
    if (!ok) return;

    final raw = await getProperty('volume');
    num? vol;
    if (raw is num) {
      vol = raw;
    } else if (raw is String) {
      vol = num.tryParse(raw);
    }
    if (vol != null) {
      await showText('Volume ${vol.round()}', durationMs: 900);
    } else {
      await showText(delta > 0 ? 'Volume +' : 'Volume −', durationMs: 700);
    }
  }

  Future<void> cycleMute() async {
    await sendCommand(['osd-msg', 'cycle', 'mute']);
    final muted = await getProperty('mute');
    if (muted == true || muted == 'yes') {
      await showText('Muted', durationMs: 900);
    } else if (muted == false || muted == 'no') {
      await showText('Unmuted', durationMs: 900);
    }
  }

  /// Jump to playlist index (0-based). Prefer [loadFile] for live IPTV.
  Future<bool> playlistPlayIndex(int index) async {
    // playlist-play-index restarts playback; set playlist-pos often does not
    // re-open live/HLS URLs.
    var ok = await sendCommand(['playlist-play-index', index]);
    if (!ok) {
      ok = await sendCommand(['set', 'playlist-pos', index]);
    }
    return ok;
  }

  Future<bool> playlistNext() async =>
      sendCommand(['playlist-next', 'force']);

  Future<bool> playlistPrev() async =>
      sendCommand(['playlist-prev', 'force']);

  /// OSD message (milliseconds).
  Future<void> showText(String text, {int durationMs = 2000}) async {
    await sendCommand(['show-text', text, durationMs]);
  }

  /// Replace current playback with [url] (reliable for live channel zap).
  Future<bool> loadFile(Uri url, {String? title}) async {
    _activeUrl = url;
    if (title != null && title.trim().isNotEmpty) {
      _activeTitle = title.trim();
    }
    // Third arg "replace" clears the current item and plays immediately.
    final ok = await sendCommand(['loadfile', url.toString(), 'replace']);
    if (!ok) {
      // Some builds want append-play style flags as separate form.
      final ok2 = await sendCommand(['loadfile', url.toString()]);
      if (!ok2) return false;
    }
    if (title != null && title.trim().isNotEmpty) {
      await setMediaTitle(title.trim());
    }
    return true;
  }

  /// True when demuxer never attached (bad URL / 403 / etc.).
  ///
  /// Intentionally **not** treating "VO not ready yet" as failure — slow
  /// VAAPI / network buffer would false-positive and kick users to the guide.
  Future<bool> isPlaybackUnhealthy() async {
    if (!isRunning) return true;
    final pause = await getProperty('pause');
    if (pause == true || pause == 'yes') return false;

    final idle = await getProperty('idle-active');
    if (idle == true || idle == 'yes') return true;

    // path/stream open failed: no current file
    final path = await getProperty('path');
    if (path == null || path == false || '$path'.isEmpty) {
      // Still starting — only unhealthy if we also see a real log error.
      return hasMeaningfulStreamError;
    }

    final pos = await getProperty('time-pos');
    // null time-pos after grace usually means demux never started.
    if (pos == null && hasMeaningfulStreamError) return true;
    if (pos == null) {
      // Buffering / slow open — not dead yet.
      return false;
    }
    return false;
  }

  /// Wait [grace], then either confirm healthy or try [fallback] (.m3u8).
  ///
  /// Returns **true** if playback looks healthy (primary or after fallback).
  Future<bool> waitUntilHealthyOrFallback(
    Uri? fallback, {
    String? title,
    Duration grace = const Duration(milliseconds: 2000),
  }) async {
    if (_userQuit) return false;
    await Future<void>.delayed(grace);
    if (!isRunning || _userQuit) return false;
    if (!await isPlaybackUnhealthy()) return true;

    if (fallback == null) {
      debugPrint('sdtv_player: stream unhealthy, no fallback URL');
      return false;
    }

    debugPrint('sdtv_player: stream unhealthy — trying fallback $fallback');
    await showText('Retrying stream (HLS)…', durationMs: 1500);
    final ok = await loadFile(fallback, title: title);
    if (!ok) return false;
    await Future<void>.delayed(grace);
    if (_userQuit || !isRunning) return false;
    final stillBad = await isPlaybackUnhealthy();
    if (stillBad) {
      debugPrint('sdtv_player: HLS fallback still unhealthy');
      return false;
    }
    debugPrint('sdtv_player: HLS fallback looks OK');
    return true;
  }

  /// Health-check after a load; on failure show a TiviMate-style error and stay.
  Future<bool> ensureHealthyOrShowError(
    Uri? fallback, {
    String? title,
    Duration grace = const Duration(milliseconds: 2000),
  }) async {
    final ok = await waitUntilHealthyOrFallback(
      fallback,
      title: title,
      grace: grace,
    );
    if (ok || _userQuit || !isRunning) return ok;
    await showPlaybackError(channelName: title);
    return false;
  }

  /// Legacy name — same as [waitUntilHealthyOrFallback].
  Future<bool> tryFallbackIfUnhealthy(
    Uri? fallback, {
    String? title,
    Duration grace = const Duration(milliseconds: 2000),
  }) =>
      waitUntilHealthyOrFallback(fallback, title: title, grace: grace);

  /// Ask mpv to quit (falls back to [stop] kill).
  Future<void> quit() async {
    _userQuit = true;
    _restartForDisplay = false;
    _restartDebounce?.cancel();
    _stopDisplayWatch();
    final ok = await sendCommand(['quit']);
    if (!ok) {
      await stop();
      return;
    }
    try {
      final p = _process;
      if (p != null) {
        await p.exitCode.timeout(const Duration(milliseconds: 800));
      }
    } catch (_) {
      await stop();
    }
  }

  /// Flutter [didChangeMetrics] (dock/undock).
  ///
  /// Important (Steam Deck / Gamescope):
  /// - **Native** external resolution is chosen when the **game process starts**.
  /// - Docking mid-session usually keeps the handheld nest (e.g. 1280×800 /
  ///   16:10) letterboxed on the TV — looks "almost full".
  /// - Respawning mpv inside that nest **cannot** fill the TV; only exiting
  ///   sdtv and launching again while docked gets a true 1080p nest.
  ///
  /// If Flutter's nest size actually changes, we still respawn mpv. If the
  /// physical TV is larger than the nest (typical dock), we hint to restart.
  Future<void> notifyDisplayChanged({int? width, int? height}) async {
    if (!_sessionActive || _userQuit) return;

    if (width != null && height != null && width >= 64 && height >= 64) {
      final pw = _processStartW ?? _targetW;
      final ph = _processStartH ?? _targetH;
      _targetW = width;
      _targetH = height;

      if (pw != null && ph != null) {
        final rw = (width - pw).abs() / pw;
        final rh = (height - ph).abs() / ph;
        if (rw >= 0.10 || rh >= 0.10) {
          debugPrint(
            'sdtv_player: nest resize ${pw}x$ph → ${width}x$height — respawn mpv',
          );
          _scheduleRespawn();
          return;
        }
      }
    }

    // Nest size unchanged (common on Deck dock) — check TV vs nest.
    unawaited(_checkDockLetterboxAndHint());
  }

  void _scheduleRespawn() {
    _restartDebounce?.cancel();
    _restartDebounce = Timer(const Duration(milliseconds: 700), () {
      unawaited(_requestRespawnForDisplay());
    });
  }

  Future<void> _requestRespawnForDisplay() async {
    if (!_sessionActive || _userQuit || _process == null) return;
    if (_activeUrl == null) return;
    final now = DateTime.now();
    if (_lastRestartAt != null &&
        now.difference(_lastRestartAt!) < const Duration(seconds: 2)) {
      return;
    }
    _lastRestartAt = now;
    debugPrint('sdtv_player: respawning mpv (nest size changed)');
    _restartForDisplay = true;
    final ok = await sendCommand(['quit']);
    if (!ok) {
      try {
        _process?.kill(ProcessSignal.sigterm);
      } catch (_) {}
    }
  }

  void _startDisplayWatch() {
    _stopDisplayWatch();
    _processStartW = _targetW;
    _processStartH = _targetH;
    _dockHintShown = false;
    // After dock settles, compare nest to real outputs.
    unawaited(() async {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (_sessionActive && !_userQuit) {
        await _checkDockLetterboxAndHint();
      }
    }());
    _displayWatch = Timer.periodic(const Duration(seconds: 5), (_) {
      unawaited(_checkDockLetterboxAndHint());
    });
  }

  void _stopDisplayWatch() {
    _displayWatch?.cancel();
    _displayWatch = null;
  }

  /// Detect *true* mid-dock letterbox: nest still looks like Deck handheld
  /// while an external panel is connected.
  ///
  /// Do **not** compare nest to the TV's max listed mode (often 4K) — a real
  /// 1080p Native session was false-positiving and nagging to relaunch.
  Future<void> _checkDockLetterboxAndHint() async {
    if (!_sessionActive || _userQuit || _process == null) return;

    // Prefer mpv's own window size when available (more accurate under nest).
    final ow = _asPositiveInt(await getProperty('osd-width'));
    final oh = _asPositiveInt(await getProperty('osd-height'));
    final nest = (ow != null && oh != null) ? (ow, oh) : _nestSize();
    if (nest == null) return;

    // Already a full HD+ nest → Native dock launch (or desktop). Never nag.
    if (!_looksLikeHandheldNest(nest.$1, nest.$2)) {
      needsAppRestartForFullDisplay = false;
      return;
    }

    // Only care if something larger than the Deck panel is actually connected.
    final hasExternal = await _hasExternalDisplayConnected();
    if (!hasExternal) {
      needsAppRestartForFullDisplay = false;
      return;
    }

    needsAppRestartForFullDisplay = true;
    debugPrint(
      'sdtv_player: handheld nest ${nest.$1}x${nest.$2} + external display '
      '— relaunch sdtv while docked for Native full screen',
    );

    // Fill the nest only (crop video); cannot paint outside Gamescope nest.
    await sendCommand(['set', 'panscan', '1.0']);
    await sendCommand(['set', 'keepaspect', 'yes']);
    await sendCommand(['set', 'fullscreen', 'yes']);

    if (_dockHintShown) return;
    _dockHintShown = true;
    await showText(
      'Docked · handheld resolution\n'
      'STEAM → Exit sdtv → open again\n'
      'for full TV (Native on launch)',
      durationMs: 7000,
    );
  }

  /// Deck-class nest: ~1280×800 / 800×1280 (with slack), not 1080p/4K.
  static bool _looksLikeHandheldNest(int w, int h) {
    final a = w < h ? w : h;
    final b = w < h ? h : w;
    // True full HD or higher — fine.
    if (a >= 1000 && b >= 1600) return false;
    if (w * h >= 1920 * 1000) return false;
    // Steam Deck panel and common Game Mode nest sizes.
    if (b <= 1400 && a <= 900) return true;
    // 16:10-ish under ~900p short side.
    final ar = b / a;
    if (ar >= 1.45 && ar <= 1.75 && a <= 900) return true;
    return false;
  }

  (int, int)? _nestSize() {
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isNotEmpty) {
        final s = views.first.physicalSize;
        final w = s.width.round();
        final h = s.height.round();
        if (w >= 64 && h >= 64) return (w, h);
      }
    } catch (_) {}
    // Prefer live mpv window size when Flutter view is wrong/obscured.
    // (filled asynchronously elsewhere; sync fallback below)
    if (_targetW != null && _targetH != null) {
      return (_targetW!, _targetH!);
    }
    if (_processStartW != null && _processStartH != null) {
      return (_processStartW!, _processStartH!);
    }
    return null;
  }

  /// True when a non-eDP connector reports connected (HDMI/DP dock).
  static Future<bool> _hasExternalDisplayConnected() async {
    try {
      final drm = Directory('/sys/class/drm');
      if (!await drm.exists()) return false;
      await for (final ent in drm.list(followLinks: true)) {
        final name = ent.path.split('/').last.toLowerCase();
        // Skip card node itself; want cardN-CONNECTOR.
        if (!name.contains('-')) continue;
        // Internal Deck panel — not "docked to TV".
        if (name.contains('edp') || name.contains('dsi') || name.contains('lvds')) {
          continue;
        }
        final statusFile = File('${ent.path}/status');
        if (!await statusFile.exists()) continue;
        final status = (await statusFile.readAsString()).trim().toLowerCase();
        if (status == 'connected') return true;
      }
    } catch (e) {
      debugPrint('sdtv_player: drm external probe failed: $e');
    }
    return false;
  }

  static int? _asPositiveInt(Object? v) {
    if (v == null) return null;
    if (v is int) return v > 0 ? v : null;
    if (v is double) return v > 0 ? v.round() : null;
    return int.tryParse('$v');
  }

  /// Snapshot Flutter view physical size (Gamescope nest) if available.
  void _seedTargetFromFlutterViews() {
    try {
      final views = ui.PlatformDispatcher.instance.views;
      if (views.isEmpty) return;
      final s = views.first.physicalSize;
      final w = s.width.round();
      final h = s.height.round();
      if (w >= 64 && h >= 64) {
        _targetW = w;
        _targetH = h;
        debugPrint('sdtv_player: seed display target ${w}x$h');
      }
    } catch (e) {
      debugPrint('sdtv_player: seed display target failed: $e');
    }
  }

  /// Play fullscreen until quit.
  ///
  /// [playlist] optional multi-entry list (category / favorites). Enables
  /// keyboard PGUP/PGDWN and in-process zap via [playlistPlayIndex].
  ///
  /// [fallbackUrl] optional HLS (.m3u8) URL tried if the primary stream fails
  /// to start (Xtream .ts → .m3u8).
  ///
  /// On display size change (Deck dock), the process is **respawned** with the
  /// current channel URL so Gamescope opens a full-size window — geometry
  /// changes on a live mpv process do not work under Gamescope.
  ///
  /// Re-entrant: if already running, returns [ExternalMpvResult.busy].
  Future<ExternalMpvResult> playFullscreen(
    Uri url, {
    List<({String title, Uri uri})>? playlist,
    int startIndex = 0,
    Uri? fallbackUrl,
    String? fallbackTitle,
  }) async {
    if (_launching || _process != null || _sessionActive) {
      debugPrint('sdtv_player: playFullscreen ignored (already running)');
      return const ExternalMpvResult(started: false, busy: true);
    }

    _sessionActive = true;
    _launching = true;
    _userQuit = false;
    _restartForDisplay = false;
    _dockHintShown = false;
    // Fresh watch — only set again if we detect dock letterboxing mid-session.
    needsAppRestartForFullDisplay = false;
    clearRecentLog();
    final startedAt = DateTime.now();

    // Track active media for dock respawn (zap updates via [loadFile]).
    final entries = playlist;
    final useListInitial = entries != null && entries.length > 1;
    final list = useListInitial ? entries : null;
    final start =
        list != null ? startIndex.clamp(0, list.length - 1) : 0;
    if (list != null) {
      _activeUrl = list[start].uri;
      _activeTitle = list[start].title;
    } else {
      _activeUrl = url;
      _activeTitle = (playlist != null && playlist.isNotEmpty)
          ? playlist.first.title
          : 'sdtv';
    }
    _activeFallback = fallbackUrl;
    _activeFallbackTitle = fallbackTitle ?? _activeTitle;

    Directory? confDir;
    try {
      final inv = await _findMpv();
      if (inv == null) {
        return const ExternalMpvResult(
          started: false,
          error:
              'mpv not found. On Deck: Desktop → Discover → install “mpv” '
              '(Flatpak io.mpv.Mpv), or set SDTV_MPV_PATH in ~/sdtv/sdtv.env '
              '(e.g. flatpak:io.mpv.Mpv or /usr/bin/mpv).',
        );
      }

      confDir = await Directory.systemTemp.createTemp('sdtv_mpv_');
      final confFile = File('${confDir.path}/input.conf');
      await confFile.writeAsString('''
# sdtv — quit back to guide
ESC quit
q quit
Q quit
BS quit
MOUSE_BTN2 quit
# Pause (lua script also forces OSC on pause)
SPACE cycle pause
p cycle pause
# Volume (keyboard / when mpv has focus) — bar OSD
UP osd-msg-bar add volume 5
DOWN osd-msg-bar add volume -5
m osd-msg cycle mute
# Channel zap within session playlist (force restarts live entries)
PGUP playlist-prev force
PGDWN playlist-next force
PLAYLIST_PREV playlist-prev force
PLAYLIST_NEXT playlist-next force
< playlist-prev force
> playlist-next force
n playlist-next force
# SDL gamepad (if mpv owns the pad)
GAMEPAD_ACTION_DOWN cycle pause
GAMEPAD_ACTION_RIGHT quit
GAMEPAD_ACTION_EAST quit
GAMEPAD_BACK quit
GAMEPAD_DPAD_UP osd-msg-bar add volume 5
GAMEPAD_DPAD_DOWN osd-msg-bar add volume -5
GAMEPAD_DPAD_LEFT playlist-prev force
GAMEPAD_DPAD_RIGHT playlist-next force
GAMEPAD_SHOULDER_L playlist-prev force
GAMEPAD_SHOULDER_R playlist-next force
GAMEPAD_START quit
GAMEPAD_GUIDE quit
''');

      // Intentionally no "force OSC on pause" script: OSC seek on live
      // rewinds the demuxer cache (old segment / wrong program audio).

      // First launch may use full playlist; dock respawns use current URL only.
      var firstLaunch = true;
      int? lastCode;
      var anyStarted = false;

      while (!_userQuit) {
        _launching = true;
        _restartForDisplay = false;
        _seedTargetFromFlutterViews();

        final ipcPath = _newIpcPath();
        _ipcPath = ipcPath;
        try {
          final stale = File(ipcPath);
          if (await stale.exists()) await stale.delete();
        } catch (_) {}

        final playUrl = _activeUrl ?? url;
        final playTitle =
            (_activeTitle != null && _activeTitle!.trim().isNotEmpty)
                ? _activeTitle!.trim()
                : 'sdtv';
        final fb = _activeFallback ?? fallbackUrl;
        final fbTitle = _activeFallbackTitle ?? fallbackTitle ?? playTitle;

        final sessionList = firstLaunch ? list : null;
        final useList = sessionList != null;
        String? playlistPath;
        if (sessionList != null) {
          playlistPath = '${confDir.path}/session.m3u';
          final buf = StringBuffer('#EXTM3U\n');
          for (final e in sessionList) {
            final title = e.title.replaceAll('\n', ' ').replaceAll(',', ' ');
            buf.writeln('#EXTINF:-1,$title');
            buf.writeln(e.uri.toString());
          }
          await File(playlistPath).writeAsString(buf.toString());
        }

        final geoArgs = <String>[];
        if (_targetW != null &&
            _targetH != null &&
            _targetW! >= 64 &&
            _targetH! >= 64) {
          final geo = '${_targetW}x$_targetH';
          geoArgs.addAll(['--geometry=$geo', '--autofit=$geo']);
        }

        final mpvArgs = <String>[
          '--fullscreen',
          '--force-window=immediate',
          '--keep-open=no',
          '--idle=no',
          '--no-terminal',
          '--msg-level=all=warn',
          '--title=sdtv',
          '--force-media-title=$playTitle',
          '--input-conf=${confFile.path}',
          '--input-ipc-server=$ipcPath',
          // No OSC: seek bar on live IPTV jumps into the old cache window.
          '--osc=no',
          '--osd-bar=yes',
          '--osd-level=1',
          '--osd-duration=2000',
          // Live-friendly: don't treat the sliding window as a scrubbable VOD.
          '--force-seekable=no',
          '--hr-seek=no',
          '--keepaspect=yes',
          '--keepaspect-window=no',
          '--video-unscaled=no',
          '--panscan=0',
          '--border=no',
          '--hwdec=vaapi,vaapi-copy,auto-copy,auto',
          '--profile=fast',
          '--framedrop=vo',
          ...geoArgs,
          ...extraArgs,
          if (useList) ...[
            '--playlist=$playlistPath',
            '--playlist-start=$start',
          ] else
            playUrl.toString(),
        ];

        late final String finalExec;
        late final List<String> finalArgv;
        if (inv.isFlatpak) {
          finalExec = 'flatpak';
          finalArgv = <String>[
            'run',
            '--filesystem=/tmp',
            '--filesystem=host',
            '--device=all',
            inv.appId!,
            ...mpvArgs,
          ];
        } else {
          finalExec = inv.executable;
          finalArgv = mpvArgs;
        }

        debugPrint(
          'sdtv_player: external mpv ${inv.label} → $finalExec '
          '${firstLaunch ? '' : '(display respawn) '}'
          '${finalArgv.length > 24 ? '${finalArgv.take(20).join(' ')} …' : finalArgv.join(' ')}',
        );

        final proc = await Process.start(
          finalExec,
          finalArgv,
          mode: ProcessStartMode.normal,
          environment: _childEnvironment(),
        );
        _process = proc;
        _launching = false;
        firstLaunch = false;
        anyStarted = true;
        _startDisplayWatch();

        unawaited(proc.stdout.drain<void>());
        unawaited(
          proc.stderr.transform(SystemEncoding().decoder).forEach((line) {
            if (line.trim().isNotEmpty) {
              _noteLog(line);
              debugPrint('mpv: $line');
            }
          }),
        );

        final hint = useList
            ? 'A pause · B back · LB/RB ch · ↑↓ vol'
            : 'A pause · B back · ↑↓ vol';
        unawaited(() async {
          await Future<void>.delayed(const Duration(milliseconds: 600));
          if (_process != proc || _userQuit) return;
          await sendCommand(['show-text', hint, 2800]);
          final ok = await waitUntilHealthyOrFallback(
            fb,
            title: fbTitle,
          );
          if (!ok && _process == proc && !_userQuit && !_restartForDisplay) {
            await showPlaybackError(channelName: fbTitle);
          }
          if (_process == proc && !_userQuit) {
            await sendCommand(['set', 'fullscreen', 'yes']);
          }
        }());

        lastCode = await proc.exitCode;
        _stopDisplayWatch();
        if (identical(_process, proc)) {
          _process = null;
        }
        _cleanupIpc();

        if (_userQuit) break;

        if (_restartForDisplay) {
          _restartForDisplay = false;
          // Let Gamescope finish settling on the new output.
          await Future<void>.delayed(const Duration(milliseconds: 400));
          if (_userQuit) break;
          debugPrint('sdtv_player: re-launching mpv after display change');
          continue;
        }

        // Natural exit (stream death / crash) — end session.
        break;
      }

      final durationMs = DateTime.now().difference(startedAt).inMilliseconds;
      return ExternalMpvResult(
        started: anyStarted,
        exitCode: lastCode,
        mpvPath: inv.label,
        durationMs: durationMs,
        userQuit: _userQuit,
      );
    } catch (e, st) {
      _stopDisplayWatch();
      _process = null;
      _cleanupIpc();
      debugPrint('sdtv_player: mpv spawn failed: $e\n$st');
      return ExternalMpvResult(
        started: false,
        error: 'Failed to start mpv: $e',
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        userQuit: _userQuit,
      );
    } finally {
      _sessionActive = false;
      _launching = false;
      _restartForDisplay = false;
      _restartDebounce?.cancel();
      _stopDisplayWatch();
      _activeUrl = null;
      _activeTitle = null;
      _activeFallback = null;
      _activeFallbackTitle = null;
      final dir = confDir;
      if (dir != null) {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  void _cleanupIpc() {
    final path = _ipcPath;
    _ipcPath = null;
    if (path == null) return;
    try {
      final f = File(path);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Kill a session we started (sign-out / app exit / B while watching).
  Future<void> stop() async {
    _userQuit = true;
    _restartForDisplay = false;
    _restartDebounce?.cancel();
    _stopDisplayWatch();
    final p = _process;
    _launching = false;
    if (p != null) {
      // Prefer graceful quit (IPC while process still "running") then SIGTERM.
      try {
        await sendCommand(['quit']);
      } catch (_) {}
      try {
        p.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        await p.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          p.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    }
    _process = null;
    _cleanupIpc();
  }
}
