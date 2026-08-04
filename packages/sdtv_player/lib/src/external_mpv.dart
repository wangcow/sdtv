import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Result of a fullscreen external [mpv] session.
class ExternalMpvResult {
  const ExternalMpvResult({
    required this.started,
    this.exitCode,
    this.error,
    this.mpvPath,
    this.busy = false,
  });

  final bool started;
  final int? exitCode;
  final String? error;
  final String? mpvPath;

  /// True when a session was already in flight (re-entry ignored).
  final bool busy;

  bool get ok => started && error == null && !busy;
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

  bool get isRunning => _process != null || _launching;

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
  static Map<String, String> _childEnvironment() {
    final env = Map<String, String>.from(Platform.environment);
    env['LD_LIBRARY_PATH'] = '/usr/lib64:/usr/lib';
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

  /// Pause / unpause via IPC.
  Future<void> cyclePause() async {
    final ok = await sendCommand(['cycle', 'pause']);
    if (!ok) {
      debugPrint('sdtv_player: cyclePause — no ipc');
    }
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
  Future<bool> loadFile(Uri url) async {
    // Third arg "replace" clears the current item and plays immediately.
    final ok = await sendCommand(['loadfile', url.toString(), 'replace']);
    if (!ok) {
      // Some builds want append-play style flags as separate form.
      return sendCommand(['loadfile', url.toString()]);
    }
    return true;
  }

  /// Ask mpv to quit (falls back to [stop] kill).
  Future<void> quit() async {
    final ok = await sendCommand(['quit']);
    if (!ok) {
      await stop();
      return;
    }
    // Give it a moment, then force-kill if still alive.
    try {
      final p = _process;
      if (p != null) {
        await p.exitCode.timeout(const Duration(milliseconds: 800));
      }
    } catch (_) {
      await stop();
    }
  }

  /// Play fullscreen until quit.
  ///
  /// [playlist] optional multi-entry list (category / favorites). Enables
  /// keyboard PGUP/PGDWN and in-process zap via [playlistPlayIndex].
  ///
  /// Re-entrant: if already running, returns [ExternalMpvResult.busy].
  Future<ExternalMpvResult> playFullscreen(
    Uri url, {
    List<({String title, Uri uri})>? playlist,
    int startIndex = 0,
  }) async {
    if (_launching || _process != null) {
      debugPrint('sdtv_player: playFullscreen ignored (already running)');
      return const ExternalMpvResult(started: false, busy: true);
    }

    _launching = true;
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
      // Keyboard maps matter when mpv has focus (desktop / Flatpak users).
      // Deck pad is usually routed by Flutter → IPC; both paths stay valid.
      await confFile.writeAsString('''
# sdtv — quit back to guide
ESC quit
q quit
Q quit
BS quit
MOUSE_BTN2 quit
# Pause
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

      final ipcPath = _newIpcPath();
      _ipcPath = ipcPath;
      try {
        final stale = File(ipcPath);
        if (await stale.exists()) await stale.delete();
      } catch (_) {}

      final entries = playlist;
      final useList = entries != null && entries.length > 1;
      final start = useList
          ? startIndex.clamp(0, entries.length - 1)
          : 0;

      String? playlistPath;
      if (useList) {
        playlistPath = '${confDir.path}/session.m3u';
        final buf = StringBuffer('#EXTM3U\n');
        for (final e in entries) {
          final title = e.title.replaceAll('\n', ' ').replaceAll(',', ' ');
          buf.writeln('#EXTINF:-1,$title');
          buf.writeln(e.uri.toString());
        }
        await File(playlistPath).writeAsString(buf.toString());
      }

      final mpvArgs = <String>[
        '--fullscreen',
        '--force-window=immediate',
        '--keep-open=no',
        '--idle=no',
        '--no-terminal',
        '--msg-level=all=warn',
        '--title=sdtv',
        '--input-conf=${confFile.path}',
        '--input-ipc-server=$ipcPath',
        '--osc=yes',
        '--osd-level=1',
        '--osd-duration=2000',
        '--hwdec=vaapi,vaapi-copy,auto-copy,auto',
        '--profile=fast',
        '--framedrop=vo',
        ...extraArgs,
        if (useList) ...[
          '--playlist=$playlistPath',
          '--playlist-start=$start',
        ] else
          url.toString(),
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
        '${finalArgv.length > 24 ? '${finalArgv.take(20).join(' ')} …' : finalArgv.join(' ')}',
      );

      final proc = await Process.start(
        finalExec,
        finalArgv,
        mode: ProcessStartMode.normal,
        environment: _childEnvironment(),
      );
      _process = proc;
      // Launch complete — playback wait is not "launching".
      _launching = false;

      unawaited(proc.stdout.drain<void>());
      unawaited(proc.stderr.transform(SystemEncoding().decoder).forEach((line) {
        if (line.trim().isNotEmpty) {
          debugPrint('mpv: $line');
        }
      }));

      final hint = useList
          ? 'A pause · B back · LB/RB ch · ↑↓ vol'
          : 'A pause · B back · ↑↓ vol';
      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await sendCommand(['show-text', hint, 2800]);
      }());

      final code = await proc.exitCode;
      _process = null;
      _cleanupIpc();

      return ExternalMpvResult(
        started: true,
        exitCode: code,
        mpvPath: inv.label,
      );
    } catch (e, st) {
      _process = null;
      _cleanupIpc();
      debugPrint('sdtv_player: mpv spawn failed: $e\n$st');
      return ExternalMpvResult(
        started: false,
        error: 'Failed to start mpv: $e',
      );
    } finally {
      _launching = false;
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
