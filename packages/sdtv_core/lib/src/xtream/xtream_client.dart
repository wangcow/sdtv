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
    try {
      return jsonDecode(body);
    } on FormatException {
      final preview =
          body.length > 120 ? '${body.substring(0, 120)}…' : body;
      throw XtreamException(
        'Invalid JSON from player_api (got HTML or text?). Preview: $preview',
      );
    }
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
