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
/// Prefer [MockXtreamClient] for CI and early development to avoid
/// stressing or risking paid accounts.
class HttpXtreamClient implements XtreamClient {
  HttpXtreamClient({
    required this.credentials,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 20),
  }) : _http = httpClient ?? http.Client();

  final XtreamCredentials credentials;
  final http.Client _http;
  final Duration timeout;

  @override
  Future<UserInfo> authenticate() async {
    final json = await _getJson(credentials.authQuery);
    final info = UserInfo.fromPlayerApiJson(json);
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
    final response = await _http.get(uri).timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw XtreamException(
        'HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    try {
      return jsonDecode(response.body);
    } on FormatException catch (e) {
      throw XtreamException('Invalid JSON: $e');
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
