import '../models/category.dart';
import '../models/live_channel.dart';
import '../xtream/xtream_exception.dart';

/// Parsed M3U / M3U8 playlist (catalog only — not a single media HLS master).
class M3uPlaylist {
  const M3uPlaylist({
    required this.categories,
    required this.channels,
    this.sourceHint = '',
  });

  final List<MediaCategory> categories;
  final List<LiveChannel> channels;
  final String sourceHint;
}

/// Parse IPTV-style M3U text (`#EXTINF` + URL lines).
///
/// You supply the playlist URL/content. sdtv does not ship channel lists.
class M3uParser {
  /// Parse playlist body. [baseUri] resolves relative stream URLs when present.
  static M3uPlaylist parse(String raw, {Uri? baseUri}) {
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = text.split('\n');
    if (lines.isEmpty || !lines.first.trim().toUpperCase().startsWith('#EXTM3U')) {
      // Some playlists omit the header; still try if we see EXTINF.
      final hasInf = lines.any((l) => l.trim().toUpperCase().startsWith('#EXTINF'));
      if (!hasInf) {
        throw XtreamException(
          'Not an M3U playlist (missing #EXTM3U / #EXTINF). '
          'Paste a playlist URL, not a single media file.',
        );
      }
    }

    final channels = <LiveChannel>[];
    final groupOrder = <String>[];
    final groupSeen = <String>{};

    String? pendingName;
    String? pendingGroup;
    String? pendingLogo;
    String? pendingEpg;

    void resetPending() {
      pendingName = null;
      pendingGroup = null;
      pendingLogo = null;
      pendingEpg = null;
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.toUpperCase().startsWith('#EXTINF')) {
        final parsed = _parseExtinf(line);
        pendingName = parsed.name;
        pendingGroup = parsed.group;
        pendingLogo = parsed.logo;
        pendingEpg = parsed.epgId;
        continue;
      }

      if (line.startsWith('#')) {
        // Skip other tags (EXTVLCOPT, etc.)
        continue;
      }

      // Stream URL line
      final url = _resolveUrl(line, baseUri);
      if (url == null) {
        resetPending();
        continue;
      }

      final group = (pendingGroup == null || pendingGroup!.trim().isEmpty)
          ? 'All channels'
          : pendingGroup!.trim();
      if (groupSeen.add(group)) {
        groupOrder.add(group);
      }

      final id = channels.length + 1;
      final name = (pendingName == null || pendingName!.trim().isEmpty)
          ? 'Channel $id'
          : pendingName!.trim();

      channels.add(
        LiveChannel(
          streamId: id,
          name: name,
          categoryId: _categoryIdFor(group),
          streamIcon: pendingLogo ?? '',
          epgChannelId: pendingEpg ?? '',
          num: id,
          streamUrl: url,
        ),
      );
      resetPending();
    }

    if (channels.isEmpty) {
      throw XtreamException('M3U playlist contained no playable entries.');
    }

    final categories = groupOrder
        .map(
          (g) => MediaCategory(
            categoryId: _categoryIdFor(g),
            categoryName: g,
          ),
        )
        .toList();

    return M3uPlaylist(categories: categories, channels: channels);
  }

  static String _categoryIdFor(String group) {
    // Stable, filesystem-safe id from group title.
    final slug = group
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'all' : slug;
  }

  static String? _resolveUrl(String line, Uri? base) {
    final t = line.trim();
    if (t.isEmpty) return null;
    final uri = Uri.tryParse(t);
    if (uri == null) return null;
    if (uri.hasScheme &&
        (uri.scheme == 'http' ||
            uri.scheme == 'https' ||
            uri.scheme == 'rtmp' ||
            uri.scheme == 'rtsp')) {
      return t;
    }
    if (base != null) {
      try {
        return base.resolve(t).toString();
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static ({String name, String? group, String? logo, String? epgId}) _parseExtinf(
    String line,
  ) {
    // #EXTINF:-1 tvg-id="x" group-title="News",Display Name
    final comma = line.lastIndexOf(',');
    final name = comma >= 0 && comma < line.length - 1
        ? line.substring(comma + 1).trim()
        : 'Channel';
    final meta = comma >= 0 ? line.substring(0, comma) : line;

    String? attr(String key) {
      final re = RegExp(
        '$key="([^"]*)"',
        caseSensitive: false,
      );
      return re.firstMatch(meta)?.group(1);
    }

    return (
      name: name,
      group: attr('group-title'),
      logo: attr('tvg-logo'),
      epgId: attr('tvg-id'),
    );
  }
}
