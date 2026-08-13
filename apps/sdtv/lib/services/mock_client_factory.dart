import 'package:flutter/services.dart';
import 'package:sdtv_core/sdtv_core.dart';

/// Loads checked-in fixture JSON as a [MockXtreamClient] (no network).
Future<MockXtreamClient> loadMockXtreamClient({
  XtreamCredentials? credentials,
}) async {
  final auth = await rootBundle.loadString('assets/mock_xtream/auth_ok.json');
  final cats =
      await rootBundle.loadString('assets/mock_xtream/live_categories.json');
  final streams =
      await rootBundle.loadString('assets/mock_xtream/live_streams.json');
  final vodCats =
      await rootBundle.loadString('assets/mock_xtream/vod_categories.json');
  final vodStreams =
      await rootBundle.loadString('assets/mock_xtream/vod_streams.json');

  return MockXtreamClient(
    authJson: auth,
    liveCategoriesJson: cats,
    liveStreamsJson: streams,
    vodCategoriesJson: vodCats,
    vodStreamsJson: vodStreams,
    credentials: credentials ??
        XtreamCredentials(
          baseUrl: 'http://mock.sdtv.local',
          username: 'mock_user',
          password: 'mock_pass',
        ),
  );
}
