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
  });

  final bool started;
  final int? exitCode;
  final String? error;
  final String? mpvPath;

  bool get ok => started && error == null;
}

/// Spawns system/bundled **mpv** fullscreen for a single URL and waits until exit.
///
/// Phase A handoff: Flutter keeps the guide; mpv owns the picture.
class ExternalMpvLauncher {
  ExternalMpvLauncher({this.extraArgs = const []});

  /// Extra CLI flags (e.g. from env later).
  final List<String> extraArgs;

  Process? _process;
  bool get isRunning => _process != null;

  /// Locate an mpv binary.
  static Future<String?> findMpvBinary() async {
    final env = Platform.environment['SDTV_MPV_PATH'];
    if (env != null && env.isNotEmpty && await File(env).exists()) {
      return env;
    }

    final candidates = <String>[
      // Next to our binary (bundle or install prefix)
      _besideExecutable('mpv'),
      // Common system paths (Steam Deck / Fedora / Arch)
      '/usr/bin/mpv',
      '/usr/local/bin/mpv',
      '/bin/mpv',
      // Flatpak host (if user installed)
      '/var/lib/flatpak/exports/bin/mpv',
    ];

    // PATH lookup
    final pathEnv = Platform.environment['PATH'] ?? '';
    for (final dir in pathEnv.split(':')) {
      if (dir.isEmpty) continue;
      candidates.add('$dir/mpv');
    }

    // Homebrew on dev machines
    final home = Platform.environment['HOME'];
    if (home != null) {
      candidates.add('$home/.linuxbrew/bin/mpv');
      candidates.add('/home/linuxbrew/.linuxbrew/bin/mpv');
    }

    final seen = <String>{};
    for (final c in candidates) {
      if (c.isEmpty || !seen.add(c)) continue;
      try {
        if (await File(c).exists()) return c;
      } catch (_) {}
    }
    return null;
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

  /// Play [url] fullscreen until the user quits mpv (or process dies).
  Future<ExternalMpvResult> playFullscreen(Uri url) async {
    if (_process != null) {
      try {
        _process!.kill();
      } catch (_) {}
      _process = null;
    }

    final mpv = await findMpvBinary();
    if (mpv == null) {
      return const ExternalMpvResult(
        started: false,
        error:
            'mpv not found. Install mpv on the Deck (Desktop → Discover / pacman) '
            'or set SDTV_MPV_PATH to the binary.',
      );
    }

    // Minimal input conf so Escape / q / B-like keys quit (Phase B expands pad map).
    final confDir = await Directory.systemTemp.createTemp('sdtv_mpv_');
    final confFile = File('${confDir.path}/input.conf');
    await confFile.writeAsString('''
# sdtv Phase A — quit back to guide
ESC quit
q quit
Q quit
BS quit
MOUSE_BTN2 quit
# Common keyboard mappings Steam may inject for B
b quit
B quit
# Pause
SPACE cycle pause
p cycle pause
''');

    final args = <String>[
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
      // Deck-friendly decode (system libva / radeonsi via parent env)
      '--hwdec=vaapi,vaapi-copy,auto-copy,auto',
      '--profile=fast',
      '--framedrop=vo',
      ...extraArgs,
      url.toString(),
    ];

    debugPrint('sdtv_player: external mpv $mpv ${args.join(' ')}');

    try {
      final proc = await Process.start(
        mpv,
        args,
        mode: ProcessStartMode.normal,
        environment: {
          ...Platform.environment,
          // Ensure child sees VAAPI hints from run-sdtv.sh
          if (Platform.environment['LIBVA_DRIVERS_PATH'] != null)
            'LIBVA_DRIVERS_PATH': Platform.environment['LIBVA_DRIVERS_PATH']!,
          if (Platform.environment['LIBVA_DRIVER_NAME'] != null)
            'LIBVA_DRIVER_NAME': Platform.environment['LIBVA_DRIVER_NAME']!,
        },
      );
      _process = proc;

      // Drain stdout/err so the pipe cannot fill and block mpv.
      unawaited(proc.stdout.drain<void>());
      unawaited(proc.stderr.transform(SystemEncoding().decoder).forEach((line) {
        if (line.trim().isNotEmpty) {
          debugPrint('mpv: $line');
        }
      }));

      final code = await proc.exitCode;
      _process = null;
      try {
        await confDir.delete(recursive: true);
      } catch (_) {}

      return ExternalMpvResult(
        started: true,
        exitCode: code,
        mpvPath: mpv,
      );
    } catch (e, st) {
      _process = null;
      debugPrint('sdtv_player: mpv spawn failed: $e\n$st');
      try {
        await confDir.delete(recursive: true);
      } catch (_) {}
      return ExternalMpvResult(
        started: false,
        error: 'Failed to start mpv: $e',
        mpvPath: mpv,
      );
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
