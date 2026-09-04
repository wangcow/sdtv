import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// On-disk poster cache (provider URLs). Disposable; LRU-capped.
class ArtworkCache {
  ArtworkCache({
    Directory? root,
    this.maxBytes = 300 * 1024 * 1024,
    this.maxFileBytes = 8 * 1024 * 1024,
    HttpClient? httpClient,
  })  : _root = root,
        _http = httpClient ?? HttpClient() {
    _http.userAgent =
        'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 '
        '(KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3';
    _http.connectionTimeout = const Duration(seconds: 8);
  }

  final Directory? _root;
  final int maxBytes;
  final int maxFileBytes;
  final HttpClient _http;
  final Map<String, Future<File?>> _inflight = {};
  Directory? _resolvedRoot;

  static const kindVod = 'vod';
  static const kindSeries = 'series';

  Future<Directory> rootDir() async {
    if (_resolvedRoot != null) return _resolvedRoot!;
    final injected = _root;
    if (injected != null) {
      _resolvedRoot = await injected.create(recursive: true);
      return _resolvedRoot!;
    }
    final home = Platform.environment['HOME'] ?? Directory.systemTemp.path;
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    final base = (xdg != null && xdg.isNotEmpty) ? xdg : '$home/.cache';
    _resolvedRoot = await Directory('$base/sdtv/art').create(recursive: true);
    return _resolvedRoot!;
  }

  /// Stable, filesystem-safe name for [scope]|[kind]|[id]|[url].
  static String fileKey({
    required String scope,
    required String kind,
    required String id,
    required String url,
  }) {
    final raw = '$scope|$kind|$id|$url';
    final bytes = utf8.encode(raw);
    var h1 = 0x811c9dc5;
    var h2 = 0x01000193;
    for (final b in bytes) {
      h1 = 0x1fffffff & ((h1 ^ b) * 16777619);
      h2 = 0x1fffffff & ((h2 ^ b) * 31 + h1);
    }
    final idPart = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final clipped = idPart.length > 24 ? idPart.substring(0, 24) : idPart;
    return '${kind}_${clipped}_${h1.toRadixString(16)}${h2.toRadixString(16)}';
  }

  Future<File?> getFile({
    required String scope,
    required String kind,
    required String id,
    required String url,
  }) {
    final u = url.trim();
    if (u.isEmpty) return Future<File?>.value(null);
    if (!u.startsWith('http://') && !u.startsWith('https://')) {
      return Future<File?>.value(null);
    }
    final name = fileKey(scope: scope, kind: kind, id: id, url: u);
    final existing = _inflight[name];
    if (existing != null) return existing;
    final fut = _openOrFetch(name: name, url: u);
    _inflight[name] = fut;
    return fut.whenComplete(() => _inflight.remove(name));
  }

  void prefetchVod({
    required String scope,
    required List<({String id, String url})> items,
    required int focusIndex,
    required int cols,
  }) {
    if (items.isEmpty) return;
    final c = cols < 1 ? 1 : cols;
    final start = (focusIndex - c * 2).clamp(0, items.length);
    final end = (focusIndex + c * 3).clamp(0, items.length);
    for (var i = start; i < end; i++) {
      final it = items[i];
      if (it.url.trim().isEmpty) continue;
      unawaited(
        getFile(scope: scope, kind: kindVod, id: it.id, url: it.url),
      );
    }
  }

  Future<File?> _openOrFetch({
    required String name,
    required String url,
  }) async {
    final dir = await rootDir();
    final dest = File('${dir.path}/$name');
    try {
      if (await dest.exists()) {
        final len = await dest.length();
        if (len > 0 && len <= maxFileBytes) {
          try {
            await dest.setLastModified(DateTime.now());
          } catch (_) {}
          return dest;
        }
      }
    } catch (_) {}

    HttpClientResponse? resp;
    IOSink? sink;
    final tmp = File('${dest.path}.part');
    try {
      final req = await _http.getUrl(Uri.parse(url)).timeout(
            const Duration(seconds: 12),
          );
      req.followRedirects = true;
      resp = await req.close().timeout(const Duration(seconds: 12));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        return null;
      }
      final declared = resp.contentLength;
      if (declared > maxFileBytes) return null;

      sink = tmp.openWrite();
      var written = 0;
      await for (final chunk in resp) {
        written += chunk.length;
        if (written > maxFileBytes) {
          await sink.close();
          try {
            await tmp.delete();
          } catch (_) {}
          return null;
        }
        sink.add(chunk);
      }
      await sink.close();
      sink = null;
      if (written == 0) {
        try {
          await tmp.delete();
        } catch (_) {}
        return null;
      }
      await tmp.rename(dest.path);
      unawaited(_evictIfNeeded());
      return dest;
    } catch (_) {
      try {
        await sink?.close();
      } catch (_) {}
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    }
  }

  Future<void> _evictIfNeeded() async {
    try {
      final dir = await rootDir();
      final files = <File>[];
      var total = 0;
      await for (final ent in dir.list(followLinks: false)) {
        if (ent is! File) continue;
        if (ent.path.endsWith('.part')) continue;
        files.add(ent);
        try {
          total += await ent.length();
        } catch (_) {}
      }
      if (total <= maxBytes) return;
      files.sort((a, b) {
        final am = a.lastModifiedSync();
        final bm = b.lastModifiedSync();
        return am.compareTo(bm);
      });
      final target = (maxBytes * 0.8).floor();
      for (final f in files) {
        if (total <= target) break;
        try {
          final n = await f.length();
          await f.delete();
          total -= n;
        } catch (_) {}
      }
    } catch (_) {}
  }
}
