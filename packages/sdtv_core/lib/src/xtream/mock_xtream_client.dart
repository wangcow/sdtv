import 'dart:convert';

import '../models/category.dart';
import '../models/credentials.dart';
import '../models/epg_program.dart';
import '../models/live_channel.dart';
import '../models/user_info.dart';
import '../models/vod_item.dart';
import '../models/vod_info.dart';
import '../models/series.dart';
import 'xtream_client.dart';
import 'xtream_exception.dart';

/// In-memory Xtream client backed by fixture JSON strings (no network).
class MockXtreamClient implements XtreamClient {
  MockXtreamClient({
    required this.authJson,
    required this.liveCategoriesJson,
    required this.liveStreamsJson,
    this.vodCategoriesJson = '[]',
    this.vodStreamsJson = '[]',
    this.vodInfoJson = '{}',
    this.seriesCategoriesJson = '[]',
    this.seriesJson = '[]',
    this.seriesInfoJson = '{}',
    XtreamCredentials? credentials,
  }) : credentials = credentials ??
            XtreamCredentials(
              baseUrl: 'http://mock.sdtv.local',
              username: 'mock',
              password: 'mock',
            );

  /// Build from already-decoded maps/lists (handy in tests).
  factory MockXtreamClient.fromDecoded({
    required Map<String, dynamic> auth,
    required List<dynamic> liveCategories,
    required List<dynamic> liveStreams,
    XtreamCredentials? credentials,
  }) {
    return MockXtreamClient(
      authJson: jsonEncode(auth),
      liveCategoriesJson: jsonEncode(liveCategories),
      liveStreamsJson: jsonEncode(liveStreams),
      credentials: credentials ??
          XtreamCredentials(
            baseUrl: 'http://mock.sdtv.local',
            username: 'mock',
            password: 'mock',
          ),
    );
  }

  final String authJson;
  final String liveCategoriesJson;
  final String liveStreamsJson;
  final String vodCategoriesJson;
  final String vodStreamsJson;
  final String vodInfoJson;
  final String seriesCategoriesJson;
  final String seriesJson;
  final String seriesInfoJson;
  final XtreamCredentials credentials;

  @override
  Future<UserInfo> authenticate() async {
    final root = jsonDecode(authJson);
    if (root is! Map<String, dynamic> && root is! Map) {
      throw XtreamException('Auth fixture must be an object');
    }
    final map = root is Map<String, dynamic>
        ? root
        : Map<String, dynamic>.from(root as Map);
    final info = UserInfo.fromPlayerApiJson(map);
    if (!info.isActive) {
      throw XtreamException('Account status: ${info.status}');
    }
    return info;
  }

  @override
  Future<List<MediaCategory>> getLiveCategories() async {
    return _parseCategories(liveCategoriesJson);
  }

  @override
  Future<List<LiveChannel>> getLiveStreams({String? categoryId}) async {
    final all = _parseChannels(liveStreamsJson);
    if (categoryId == null) return all;
    return all.where((c) => c.categoryId == categoryId).toList();
  }

  /// Public demo HLS — mock catalog must never hand mpv a fake relative path
  /// like `t/live/t/t/103.ts` from placeholder form fields.
  static final Uri mockPlaybackUri = Uri.parse(
    'https://devstreaming-cdn.apple.com/videos/streaming/examples/'
    'img_bipbop_adv_example_fmp4/master.m3u8',
  );

  @override
  Uri livePlayUrl(int streamId, {String extension = 'ts'}) => mockPlaybackUri;

  @override
  Future<List<MediaCategory>> getVodCategories() async {
    return _parseCategories(vodCategoriesJson);
  }

  @override
  Future<List<VodItem>> getVodStreams({String? categoryId}) async {
    final json = jsonDecode(vodStreamsJson);
    if (json is! List) {
      throw XtreamException('VOD streams fixture must be an array');
    }
    final all = json.map((item) {
      if (item is Map<String, dynamic>) return VodItem.fromJson(item);
      if (item is Map) {
        return VodItem.fromJson(Map<String, dynamic>.from(item));
      }
      throw XtreamException('VOD stream row must be an object');
    }).toList();
    if (categoryId == null) return all;
    return all.where((c) => c.categoryId == categoryId).toList();
  }

  @override
  Uri vodPlayUrl(VodItem item) => mockPlaybackUri;

  @override
  Future<VodInfo> getVodInfo(int vodId) async {
    VodItem? fallback;
    try {
      final all = await getVodStreams();
      for (final v in all) {
        if (v.streamId == vodId) {
          fallback = v;
          break;
        }
      }
    } catch (_) {}

    try {
      final root = jsonDecode(vodInfoJson);
      if (root is Map) {
        final raw = root['$vodId'] ?? root[vodId];
        if (raw is Map) {
          final map = raw is Map<String, dynamic>
              ? raw
              : Map<String, dynamic>.from(raw);
          return VodInfo.fromXtreamJson(map, fallback: fallback);
        }
      }
    } catch (_) {}

    if (fallback != null) return VodInfo.fromVodItem(fallback);
    return VodInfo(title: 'Title $vodId');
  }

  @override
  Future<List<MediaCategory>> getSeriesCategories() async {
    return _parseCategories(seriesCategoriesJson);
  }

  @override
  Future<List<SeriesItem>> getSeries({String? categoryId}) async {
    final json = jsonDecode(seriesJson);
    if (json is! List) {
      throw XtreamException('Series fixture must be an array');
    }
    final all = json.map((item) {
      if (item is Map<String, dynamic>) return SeriesItem.fromJson(item);
      if (item is Map) {
        return SeriesItem.fromJson(Map<String, dynamic>.from(item));
      }
      throw XtreamException('Series row must be an object');
    }).toList();
    if (categoryId == null) return all;
    return all.where((s) => s.categoryId == categoryId).toList();
  }

  @override
  Future<SeriesCatalog> getSeriesInfo(int seriesId) async {
    SeriesItem? fallback;
    try {
      final all = await getSeries();
      for (final s in all) {
        if (s.seriesId == seriesId) {
          fallback = s;
          break;
        }
      }
    } catch (_) {}
    try {
      final root = jsonDecode(seriesInfoJson);
      if (root is Map) {
        final raw = root['$seriesId'] ?? root[seriesId];
        if (raw is Map) {
          final map = raw is Map<String, dynamic>
              ? raw
              : Map<String, dynamic>.from(raw);
          return SeriesCatalog.fromXtreamJson(map, fallback: fallback);
        }
      }
    } catch (_) {}
    return SeriesCatalog(
      info: fallback != null
          ? VodInfo.fromVodItem(fallback.asVodItem)
          : VodInfo(title: 'Series $seriesId'),
      seasons: const [],
    );
  }

  @override
  Uri seriesPlayUrl(SeriesEpisode episode) => mockPlaybackUri;

  /// Synthetic now/next so demo mode exercises the mini guide.
  @override
  Future<ShortEpg> getShortEpg(int streamId, {int limit = 4}) async {
    final now = DateTime.now();
    // Align slots to half-hours so progress bars move during a session.
    final slotMin = now.minute < 30 ? 0 : 30;
    final slotStart = DateTime(now.year, now.month, now.day, now.hour, slotMin);
    final names = _mockProgramNames(streamId);
    final lim = limit.clamp(1, 8);
    final listings = <EpgProgram>[];
    for (var i = 0; i < lim; i++) {
      final start = slotStart.add(Duration(minutes: 30 * i));
      final end = start.add(const Duration(minutes: 30));
      listings.add(
        EpgProgram(
          id: 'mock-$streamId-$i',
          title: names[i % names.length],
          description: 'Mock short EPG for stream $streamId',
          start: start,
          end: end,
          channelId: 'mock.$streamId',
        ),
      );
    }
    return ShortEpg(
      streamId: streamId,
      listings: listings,
      fetchedAt: now,
    );
  }

  /// ~24h of 30/60-minute slots so the TV Guide grid has something to show.
  @override
  Future<ShortEpg> getSimpleEpg(int streamId) async {
    final now = DateTime.now();
    final slotMin = now.minute < 30 ? 0 : 30;
    final slotStart = DateTime(now.year, now.month, now.day, now.hour, slotMin);
    final origin = slotStart.subtract(const Duration(hours: 4));
    final names = _mockProgramNames(streamId);
    final listings = <EpgProgram>[];
    var t = origin;
    for (var i = 0; i < 48; i++) {
      final durMin = (i + streamId) % 3 == 0 ? 60 : 30;
      final end = t.add(Duration(minutes: durMin));
      listings.add(
        EpgProgram(
          id: 'mock-$streamId-$i',
          title: names[i % names.length],
          description:
              'Mock TV Guide listing for stream $streamId · ${names[i % names.length]}.',
          start: t,
          end: end,
          channelId: 'mock.$streamId',
        ),
      );
      t = end;
    }
    return ShortEpg(
      streamId: streamId,
      listings: listings,
      fetchedAt: now,
    );
  }

  static List<String> _mockProgramNames(int streamId) {
    switch (streamId % 4) {
      case 0:
        return const [
          'Morning Briefing',
          'World Desk',
          'Market Watch',
          'Nightly Roundup',
        ];
      case 1:
        return const [
          'Live Match: Demo FC',
          'Halftime Analysis',
          'Sports Desk',
          'Highlights Hour',
        ];
      case 2:
        return const [
          'Sitcom Rerun',
          'Prime Drama',
          'Late Movie',
          'After Hours',
        ];
      default:
        return const [
          'Open Mic',
          'Talk Back',
          'Documentary Cut',
          'Encore',
        ];
    }
  }

  List<MediaCategory> _parseCategories(String raw) {
    final json = jsonDecode(raw);
    if (json is! List) {
      throw XtreamException('Categories fixture must be an array');
    }
    return json.map((item) {
      final map = item is Map<String, dynamic>
          ? item
          : Map<String, dynamic>.from(item as Map);
      return MediaCategory.fromJson(map);
    }).toList();
  }

  List<LiveChannel> _parseChannels(String raw) {
    final json = jsonDecode(raw);
    if (json is! List) {
      throw XtreamException('Live streams fixture must be an array');
    }
    return json.map((item) {
      final map = item is Map<String, dynamic>
          ? item
          : Map<String, dynamic>.from(item as Map);
      return LiveChannel.fromJson(map);
    }).toList();
  }
}
