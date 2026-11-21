import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/services/settings_store.dart';

void main() {
  late Directory home;
  setUp(() => home = Directory.systemTemp.createTempSync('sdtv_prefs_'));
  tearDown(() => home.deleteSync(recursive: true));

  File prefs(String id) => File('${home.path}/$id/shared_preferences.json');

  test('old settings are copied to the new app ID once', () {
    prefs('org.wangcow.sdtv')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"old":1}');
    SettingsStore.migrateLinuxPrefs(dataHome: home.path);
    expect(prefs('org.wangcow.SDTV').readAsStringSync(), '{"old":1}');
    expect(prefs('org.wangcow.sdtv').existsSync(), isTrue); // backup kept
  });

  test('existing new settings are never overwritten', () {
    prefs('org.wangcow.sdtv')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"old":1}');
    prefs('org.wangcow.SDTV')
      ..createSync(recursive: true)
      ..writeAsStringSync('{"new":2}');
    SettingsStore.migrateLinuxPrefs(dataHome: home.path);
    expect(prefs('org.wangcow.SDTV').readAsStringSync(), '{"new":2}');
  });

  test('nothing to migrate is a no-op', () {
    SettingsStore.migrateLinuxPrefs(dataHome: home.path);
    expect(prefs('org.wangcow.SDTV').existsSync(), isFalse);
  });
}
