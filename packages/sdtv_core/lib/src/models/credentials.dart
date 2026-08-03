/// Xtream Codes login parameters. Never log [password].
class XtreamCredentials {
  XtreamCredentials({
    required String baseUrl,
    required this.username,
    required this.password,
  }) : baseUrl = normalizeBaseUrl(baseUrl);

  /// Server base, e.g. `http://example.com:8080` (no trailing slash).
  final String baseUrl;
  final String username;
  final String password;

  /// Ensure `http://` / `https://` and strip trailing slash.
  ///
  /// Bare values like `t` must not become relative file paths
  /// (`/tmp/live/t/t/103.ts`) under mpv.
  static String normalizeBaseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return s;
    if (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    final lower = s.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      s = 'http://$s';
    }
    return s;
  }

  /// True when [baseUrl] looks like a usable host (scheme + non-empty host).
  static bool isPlausibleServerUrl(String raw) {
    final s = normalizeBaseUrl(raw);
    if (s.isEmpty) return false;
    final uri = Uri.tryParse(s);
    if (uri == null) return false;
    if (uri.scheme != 'http' && uri.scheme != 'https') return false;
    if (uri.host.isEmpty) return false;
    // Reject single-letter / nonsense hosts like "t" used as placeholder tests.
    if (uri.host.length < 2) return false;
    return true;
  }

  Uri get playerApiUri => Uri.parse('$baseUrl/player_api.php');

  /// Live stream play URL (provider-dependent extension).
  Uri liveStreamUri(int streamId, {String extension = 'ts'}) {
    return Uri.parse(
      '$baseUrl/live/$username/$password/$streamId.$extension',
    );
  }

  Map<String, String> get authQuery => {
        'username': username,
        'password': password,
      };

  @override
  String toString() =>
      'XtreamCredentials(baseUrl: $baseUrl, username: $username, password: ***)';
}
