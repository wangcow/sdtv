import 'package:http/http.dart' as http;

import '../xtream/xtream_exception.dart';
import 'm3u_parser.dart';

/// Fetch and parse a remote M3U playlist URL.
class M3uLoader {
  M3uLoader({
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 30),
    this.userAgent =
        'Mozilla/5.0 (compatible; sdtv/0.1; +https://github.com/wangcow/sdtv)',
  }) : _http = httpClient ?? http.Client();

  final http.Client _http;
  final Duration timeout;
  final String userAgent;

  /// Download [playlistUrl] and parse entries.
  Future<M3uPlaylist> load(String playlistUrl) async {
    final raw = playlistUrl.trim();
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      throw XtreamException(
        'M3U URL must start with http:// or https://',
      );
    }

    late final http.Response response;
    try {
      response = await _http
          .get(
            uri,
            headers: {
              'User-Agent': userAgent,
              'Accept': '*/*',
            },
          )
          .timeout(timeout);
    } on Exception catch (e) {
      throw XtreamException('Failed to download M3U: $e');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XtreamException(
        'M3U download HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    final body = response.body;
    if (body.trim().isEmpty) {
      throw XtreamException('M3U playlist was empty');
    }

    // Cap size — huge lists are OK up to a few MB; guard runaway responses.
    if (body.length > 8 * 1024 * 1024) {
      throw XtreamException('M3U playlist too large (>8MB)');
    }

    return M3uParser.parse(body, baseUri: uri);
  }

  void close() => _http.close();
}
