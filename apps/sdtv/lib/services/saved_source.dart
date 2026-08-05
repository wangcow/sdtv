import 'package:sdtv_core/sdtv_core.dart';

/// A user-saved playlist / panel entry (local only).
enum SavedSourceKind {
  demo,
  m3u,
  xtream,
}

class SavedSource {
  const SavedSource({
    required this.id,
    required this.kind,
    required this.label,
    this.m3uUrl,
    this.baseUrl,
    this.username,
    this.password,
  });

  final String id;
  final SavedSourceKind kind;
  final String label;
  final String? m3uUrl;
  final String? baseUrl;
  final String? username;
  final String? password;

  static String normalizeBase(String base) =>
      base.trim().replaceAll(RegExp(r'/+$'), '');

  static String idForDemo() => 'demo';

  static String idForM3u(String url) => 'm3u:${url.trim()}';

  static String idForXtream(String baseUrl, String username) =>
      'xtream:${normalizeBase(baseUrl)}|${username.trim()}';

  factory SavedSource.demo({String label = 'Demo playlist'}) => SavedSource(
        id: idForDemo(),
        kind: SavedSourceKind.demo,
        label: label,
      );

  factory SavedSource.m3u({
    required String url,
    String? label,
  }) {
    final u = url.trim();
    String lab = label?.trim() ?? '';
    if (lab.isEmpty) {
      try {
        final host = Uri.parse(u).host;
        lab = host.isEmpty ? 'M3U playlist' : 'M3U · $host';
      } catch (_) {
        lab = 'M3U playlist';
      }
    }
    return SavedSource(
      id: idForM3u(u),
      kind: SavedSourceKind.m3u,
      label: lab,
      m3uUrl: u,
    );
  }

  factory SavedSource.xtream({
    required XtreamCredentials credentials,
    String? label,
  }) {
    final base = normalizeBase(credentials.baseUrl);
    final user = credentials.username.trim();
    String lab = label?.trim() ?? '';
    if (lab.isEmpty) {
      try {
        final host = Uri.parse(base).host;
        lab = host.isEmpty ? 'Xtream · $user' : 'Xtream · $user@$host';
      } catch (_) {
        lab = 'Xtream · $user';
      }
    }
    return SavedSource(
      id: idForXtream(base, user),
      kind: SavedSourceKind.xtream,
      label: lab,
      baseUrl: base,
      username: user,
      password: credentials.password,
    );
  }

  XtreamCredentials? get credentials {
    if (kind != SavedSourceKind.xtream) return null;
    final b = baseUrl;
    final u = username;
    final p = password;
    if (b == null || u == null || p == null) return null;
    if (b.isEmpty || u.isEmpty || p.isEmpty) return null;
    return XtreamCredentials(baseUrl: b, username: u, password: p);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind.name,
        'label': label,
        if (m3uUrl != null) 'm3uUrl': m3uUrl,
        if (baseUrl != null) 'baseUrl': baseUrl,
        if (username != null) 'username': username,
        if (password != null) 'password': password,
      };

  factory SavedSource.fromJson(Map<String, dynamic> json) {
    final kindName = '${json['kind'] ?? 'm3u'}';
    final kind = SavedSourceKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => SavedSourceKind.m3u,
    );
    return SavedSource(
      id: '${json['id'] ?? ''}',
      kind: kind,
      label: '${json['label'] ?? 'Saved'}',
      m3uUrl: json['m3uUrl']?.toString(),
      baseUrl: json['baseUrl']?.toString(),
      username: json['username']?.toString(),
      password: json['password']?.toString(),
    );
  }

  String get kindBadge {
    switch (kind) {
      case SavedSourceKind.demo:
        return 'DEMO';
      case SavedSourceKind.m3u:
        return 'M3U';
      case SavedSourceKind.xtream:
        return 'LIVE';
    }
  }
}
