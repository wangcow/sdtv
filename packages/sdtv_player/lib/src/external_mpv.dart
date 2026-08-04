import 'dart:async';
import 'dart:io';

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
///
/// On Steam Deck, Discover usually installs **Flatpak** mpv (`io.mpv.Mpv`), not
/// `/usr/bin/mpv`. We look for both.
class ExternalMpvLauncher {
  ExternalMpvLauncher({this.extraArgs = const []});

  /// Extra CLI flags (e.g. from env later).
  final List<String> extraArgs;

  Process? _process;

  /// True from spawn begin until process exit (covers the gap before PID exists).
  bool _launching = false;

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

    // Flatpak export scripts are named after the app id, not "mpv".
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

  /// Play [url] fullscreen until the user quits mpv (or process dies).
  ///
  /// Re-entrant: if a session is already launching/running, returns
  /// [ExternalMpvResult.busy] and does **not** spawn another process.
  Future<ExternalMpvResult> playFullscreen(Uri url) async {
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
      await confFile.writeAsString('''
# sdtv Phase A — quit back to guide
ESC quit
q quit
Q quit
BS quit
MOUSE_BTN2 quit
b quit
B quit
SPACE cycle pause
p cycle pause
''');

      final mpvArgs = <String>[
        '--fullscreen',
        '--force-window=immediate',
        '--keep-open=no',
        '--idle=no',
        '--no-terminal',
        '--msg-level=all=warn',
        '--title=sdtv',
        '--input-conf=${confFile.path}',
        '--osc=yes',
        '--osd-level=1',
        '--hwdec=vaapi,vaapi-copy,auto-copy,auto',
        '--profile=fast',
        '--framedrop=vo',
        ...extraArgs,
        url.toString(),
      ];

      late final String finalExec;
      late final List<String> finalArgv;
      if (inv.isFlatpak) {
        finalExec = 'flatpak';
        finalArgv = <String>[
          'run',
          // Temp input.conf + any local playlist files.
          '--filesystem=/tmp',
          '--filesystem=host',
          inv.appId!,
          ...mpvArgs,
        ];
      } else {
        finalExec = inv.executable;
        finalArgv = mpvArgs;
      }

      debugPrint(
        'sdtv_player: external mpv ${inv.label} → $finalExec ${finalArgv.join(' ')}',
      );

      final proc = await Process.start(
        finalExec,
        finalArgv,
        mode: ProcessStartMode.normal,
        environment: _childEnvironment(),
      );
      _process = proc;

      unawaited(proc.stdout.drain<void>());
      unawaited(proc.stderr.transform(SystemEncoding().decoder).forEach((line) {
        if (line.trim().isNotEmpty) {
          debugPrint('mpv: $line');
        }
      }));

      final code = await proc.exitCode;
      _process = null;

      return ExternalMpvResult(
        started: true,
        exitCode: code,
        mpvPath: inv.label,
      );
    } catch (e, st) {
      _process = null;
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

  /// Kill a session we started (sign-out / app exit).
  Future<void> stop() async {
    final p = _process;
    _process = null;
    if (p == null) return;
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
}
