import 'dart:convert';

/// One EPG listing (now/next or grid cell).
class EpgProgram {
  const EpgProgram({
    required this.title,
    required this.start,
    required this.end,
    this.id = '',
    this.description = '',
    this.channelId = '',
  });

  final String id;
  final String title;
  final String description;
  final DateTime start;
  final DateTime end;
  final String channelId;

  Duration get duration {
    final d = end.difference(start);
    return d.isNegative ? Duration.zero : d;
  }

  bool isLiveAt(DateTime t) {
    // Inclusive start, exclusive end — matches typical TV guide windows.
    return !t.isBefore(start) && t.isBefore(end);
  }

  /// 0.0–1.0 progress through the slot at [t]; 0 if not live / unknown duration.
  double progressAt(DateTime t) {
    if (!isLiveAt(t)) {
      if (t.isBefore(start)) return 0;
      return 1;
    }
    final total = duration.inMilliseconds;
    if (total <= 0) return 0;
    final elapsed = t.difference(start).inMilliseconds.clamp(0, total);
    return elapsed / total;
  }

  /// Short wall-clock range, e.g. `8:00–9:00 PM` (local).
  String timeRangeLabel({bool use24h = false}) {
    return '${_fmtTime(start, use24h: use24h)}–${_fmtTime(end, use24h: use24h)}';
  }

  String startTimeLabel({bool use24h = false}) =>
      _fmtTime(start, use24h: use24h);

  static String _fmtTime(DateTime t, {bool use24h = false}) {
    if (use24h) {
      final h = t.hour.toString().padLeft(2, '0');
      final m = t.minute.toString().padLeft(2, '0');
      return '$h:$m';
    }
    final hour24 = t.hour;
    final hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12;
    final m = t.minute.toString().padLeft(2, '0');
    final ampm = hour24 >= 12 ? 'PM' : 'AM';
    return '$hour12:$m $ampm';
  }

  /// Decode Xtream short-EPG / simple-data-table row.
  ///
  /// Titles and descriptions are often base64; timestamps may be unix seconds
  /// or `YYYY-MM-DD HH:MM:SS` strings.
  factory EpgProgram.fromXtreamJson(Map<String, dynamic> json) {
    final title = _decodeMaybeBase64('${json['title'] ?? ''}');
    final desc = _decodeMaybeBase64('${json['description'] ?? ''}');
    final start = _parseXtreamTime(
      json['start_timestamp'] ?? json['start'],
      fallback: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
    final end = _parseXtreamTime(
      json['stop_timestamp'] ?? json['end'] ?? json['end_timestamp'],
      fallback: start.add(const Duration(hours: 1)),
    );
    return EpgProgram(
      id: '${json['id'] ?? ''}',
      title: title.isEmpty ? 'Unknown program' : title,
      description: desc,
      start: start.toLocal(),
      end: end.toLocal(),
      channelId: '${json['channel_id'] ?? json['epg_id'] ?? ''}',
    );
  }

  /// Prefer base64 (common on Xtream panels); fall back to raw text.
  static String _decodeMaybeBase64(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    // Avoid decoding short plain titles that happen to look like base64-ish.
    if (s.length < 4 || s.contains(' ')) return s;
    try {
      final decoded = utf8.decode(base64.decode(s), allowMalformed: true).trim();
      // Reject garbage (control-heavy) results.
      if (decoded.isEmpty) return s;
      final printable = decoded.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '');
      if (printable.length < decoded.length * 0.8) return s;
      return printable;
    } catch (_) {
      return s;
    }
  }

  static DateTime _parseXtreamTime(Object? value, {required DateTime fallback}) {
    if (value == null) return fallback;
    if (value is int) {
      // Unix seconds vs milliseconds.
      if (value > 1e12) {
        return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
      }
      return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
    }
    final s = value.toString().trim();
    if (s.isEmpty) return fallback;
    final asInt = int.tryParse(s);
    if (asInt != null) {
      if (asInt > 1e12) {
        return DateTime.fromMillisecondsSinceEpoch(asInt, isUtc: true);
      }
      // 10-digit unix seconds
      if (asInt > 1e8) {
        return DateTime.fromMillisecondsSinceEpoch(asInt * 1000, isUtc: true);
      }
    }
    // "2024-01-15 20:00:00" — treat as local wall time from panel.
    final normalized = s.contains('T') ? s : s.replaceFirst(' ', 'T');
    final parsed = DateTime.tryParse(normalized);
    if (parsed != null) {
      // If no zone, DateTime.tryParse returns local-ish naive; keep as local.
      return parsed.isUtc ? parsed.toLocal() : parsed;
    }
    return fallback;
  }
}

/// Short EPG window for one channel (typically now + next).
class ShortEpg {
  const ShortEpg({
    required this.streamId,
    required this.listings,
    this.fetchedAt,
  });

  final int streamId;
  final List<EpgProgram> listings;
  final DateTime? fetchedAt;

  bool get isEmpty => listings.isEmpty;

  /// Program airing at [t], if any.
  EpgProgram? nowAt([DateTime? t]) {
    final when = t ?? DateTime.now();
    for (final p in listings) {
      if (p.isLiveAt(when)) return p;
    }
    return null;
  }

  /// Next program after the live one, or first future listing if nothing is live.
  EpgProgram? nextAt([DateTime? t]) {
    final when = t ?? DateTime.now();
    final live = nowAt(when);
    EpgProgram? best;
    for (final p in listings) {
      if (live != null) {
        // Adjacent or later slots: start >= live.end
        if (p.start.isBefore(live.end)) continue;
      } else {
        // Nothing airing — first listing that starts at/after [when]
        if (p.start.isBefore(when)) continue;
      }
      if (best == null || p.start.isBefore(best.start)) best = p;
    }
    return best;
  }

  /// TiviMate-style multi-line OSD (channel + now + next).
  String formatOsd({
    required String channelLabel,
    String? prefix,
    DateTime? at,
    bool use24h = false,
  }) {
    final when = at ?? DateTime.now();
    final now = nowAt(when);
    final next = nextAt(when);
    final buf = StringBuffer();
    if (prefix != null && prefix.isNotEmpty) {
      buf.writeln('$prefix $channelLabel');
    } else {
      buf.writeln(channelLabel);
    }
    if (now != null) {
      final pct = (now.progressAt(when) * 100).round().clamp(0, 100);
      final bar = _progressBar(now.progressAt(when));
      final title = _clip(now.title, 48);
      buf.writeln(
        'NOW  ${now.timeRangeLabel(use24h: use24h)}  $title',
      );
      buf.writeln('     $bar  $pct%');
    } else {
      buf.writeln('NOW  (no program data)');
    }
    if (next != null) {
      final title = _clip(next.title, 48);
      buf.write(
        'NEXT ${next.startTimeLabel(use24h: use24h)}  $title',
      );
    } else if (now != null) {
      buf.write('NEXT —');
    }
    return buf.toString();
  }

  /// One-line guide subtitle under a channel name.
  String? guideSubtitle({DateTime? at, bool use24h = false}) {
    final when = at ?? DateTime.now();
    final now = nowAt(when);
    if (now == null) return null;
    final title = _clip(now.title, 40);
    return '${now.timeRangeLabel(use24h: use24h)}  $title';
  }

  static String _clip(String s, int max) {
    final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.length <= max) return t;
    return '${t.substring(0, max - 1)}…';
  }

  static String _progressBar(double p, {int width = 10}) {
    final filled = (p.clamp(0.0, 1.0) * width).round().clamp(0, width);
    return '[${'=' * filled}${'-' * (width - filled)}]';
  }
}
