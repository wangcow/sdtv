import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/category.dart';
import '../models/credentials.dart';
import '../models/live_channel.dart';
import '../models/user_info.dart';
import 'xtream_exception.dart';

/// Abstraction over Xtream player_api so UI can use live or mock clients.
abstract class XtreamClient {
  Future<UserInfo> authenticate();
  Future<List<MediaCategory>> getLiveCategories();
  Future<List<LiveChannel>> getLiveStreams({String? categoryId});
  Uri livePlayUrl(int streamId, {String extension = 'ts'});
}

/// HTTP implementation of [XtreamClient] against a real provider.
///
/// Prefer [MockXtreamClient] for CI and demo mode.
class HttpXtreamClient implements XtreamClient {
  HttpXtreamClient({
    required this.credentials,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 25),
    this.userAgent = 'sdtv/0.1 (Steam Deck; Flutter; libmpv)',
  }) : _http = httpClient ?? http.Client();

  final XtreamCredentials credentials;
  final http.Client _http;
  final Duration timeout;
  final String userAgent;

  Map<String, String> get _headers => {
        'User-Agent': userAgent,
        'Accept': 'application/json, text/plain, */*',
      };

  @override
  Future<UserInfo> authenticate() async {
    final json = await _getJson(credentials.authQuery);
    if (json is! Map) {
      throw XtreamException(
        'Unexpected auth response (not a JSON object). '
        'Check server URL ends at the panel root (no /player_api.php).',
      );
    }
    final map = json is Map<String, dynamic>
        ? json
        : Map<String, dynamic>.from(json);
    final info = UserInfo.fromPlayerApiJson(map);
    if (info.username.isEmpty && info.status.isEmpty) {
      throw XtreamException(
        'Login failed — empty account info. Check URL, username, and password.',
      );
    }
    if (!info.isActive && info.status.isNotEmpty) {
      throw XtreamException('Account status: ${info.status}');
    }
    return info;
  }

  @override
  Future<List<MediaCategory>> getLiveCategories() async {
    final json = await _getJson({
      ...credentials.authQuery,
      'action': 'get_live_categories',
    });
    return _parseList(json, MediaCategory.fromJson);
  }

  @override
  Future<List<LiveChannel>> getLiveStreams({String? categoryId}) async {
    final query = {
      ...credentials.authQuery,
      'action': 'get_live_streams',
      if (categoryId != null) 'category_id': categoryId,
    };
    final json = await _getJson(query);
    return _parseList(json, LiveChannel.fromJson);
  }

  @override
  Uri livePlayUrl(int streamId, {String extension = 'ts'}) =>
      credentials.liveStreamUri(streamId, extension: extension);

  Future<dynamic> _getJson(Map<String, String> query) async {
    final uri = credentials.playerApiUri.replace(queryParameters: query);
    late final http.Response response;
    try {
      response = await _http.get(uri, headers: _headers).timeout(timeout);
    } on Exception catch (e) {
      throw XtreamException(
        'Network error reaching ${credentials.baseUrl}: $e',
      );
    }
    if (response.statusCode == 401 || response.statusCode == 403) {
      throw XtreamException(
        'Auth rejected (HTTP ${response.statusCode}). Check username/password.',
        statusCode: response.statusCode,
      );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XtreamException(
        'HTTP ${response.statusCode} from player_api.php',
        statusCode: response.statusCode,
      );
    }
    final body = response.body.trim();
    if (body.isEmpty) {
      throw XtreamException('Empty response from player_api.php');
    }

    // Happy path: JSON object/array.
    if (body.startsWith('{') || body.startsWith('[')) {
      try {
        return jsonDecode(body);
      } on FormatException catch (e) {
        throw XtreamException('Invalid JSON from player_api: $e');
      }
    }

    // XUI.one and some panels return HTML error pages for bad logins
    // (e.g. title "INVALID_CREDENTIALS") instead of JSON.
    final htmlHint = _parseHtmlApiError(body);
    if (htmlHint != null) {
      throw XtreamException(htmlHint);
    }

    final preview = body.length > 100 ? '${body.substring(0, 100)}…' : body;
    throw XtreamException(
      'player_api did not return JSON. '
      'URL tried: $uri — response starts with: $preview',
    );
  }

  /// Map known panel HTML error pages to short user-facing messages.
  static String? _parseHtmlApiError(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('invalid_credentials') ||
        lower.contains('username or password is invalid') ||
        lower.contains('invalid username') ||
        lower.contains('wrong username') ||
        lower.contains('auth failed') ||
        lower.contains('authentication failed')) {
      return 'Username or password is invalid '
          '(panel rejected login). Double-check both fields.';
    }
    if (lower.contains('expired') || lower.contains('account expired')) {
      return 'Account expired on the provider panel.';
    }
    if (lower.contains('banned') || lower.contains('disabled')) {
      return 'Account disabled or banned on the provider panel.';
    }
    if (lower.contains('max connections') ||
        lower.contains('too many connections')) {
      return 'Too many connections for this account.';
    }
    if (lower.contains('xui.one') || lower.contains('xui.one - debug')) {
      // Generic XUI HTML error — try to pull <h2>…</h2>
      final h2 = RegExp(
        r'<h2[^>]*>\s*([^<]+?)\s*</h2>',
        caseSensitive: false,
      ).firstMatch(body);
      if (h2 != null) {
        final code = h2.group(1)!.trim();
        if (code.isNotEmpty && code.toLowerCase() != 'xui.one') {
          return 'Provider error: $code';
        }
      }
      return 'Provider returned an HTML error page (not JSON). '
          'Check username/password and that the server URL is correct.';
    }
    if (lower.contains('<html') || lower.contains('<!doctype')) {
      return 'Server returned a web page instead of the Xtream API. '
          'Confirm the URL is the panel host (e.g. http://host:port), '
          'not a website homepage, and credentials are correct.';
    }
    return null;
  }

  List<T> _parseList<T>(
    dynamic json,
    T Function(Map<String, dynamic>) fromJson,
  ) {
    if (json is! List) {
      throw XtreamException('Expected JSON array, got ${json.runtimeType}');
    }
    return json.map((item) {
      if (item is Map<String, dynamic>) return fromJson(item);
      if (item is Map) return fromJson(Map<String, dynamic>.from(item));
      throw XtreamException('Expected object in array');
    }).toList();
  }

  void close() => _http.close();
}
