/// Xtream Codes login parameters. Never log [password].
class XtreamCredentials {
  const XtreamCredentials({
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  /// Server base, e.g. `http://example.com:8080` (no trailing slash).
  final String baseUrl;
  final String username;
  final String password;

  Uri get playerApiUri {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse('$base/player_api.php');
  }

  /// Live stream play URL (provider-dependent extension).
  Uri liveStreamUri(int streamId, {String extension = 'ts'}) {
    final base = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    return Uri.parse(
      '$base/live/$username/$password/$streamId.$extension',
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
