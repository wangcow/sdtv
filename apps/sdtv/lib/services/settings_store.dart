import 'package:shared_preferences/shared_preferences.dart';
import 'package:sdtv_core/sdtv_core.dart';

/// Local-only Xtream credentials + prefs. Never phones home.
class SettingsStore {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static const _kBaseUrl = 'xtream.baseUrl';
  static const _kUsername = 'xtream.username';
  static const _kPassword = 'xtream.password';
  static const _kUseDemo = 'xtream.useDemo';
  static const _kHasSession = 'xtream.hasSession';
  static const _kUseM3u = 'playlist.useM3u';
  static const _kM3uUrl = 'playlist.m3uUrl';

  static Future<SettingsStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    return SettingsStore(prefs);
  }

  bool get hasSavedSession => _prefs.getBool(_kHasSession) ?? false;

  bool get useDemo => _prefs.getBool(_kUseDemo) ?? true;

  bool get useM3u => _prefs.getBool(_kUseM3u) ?? false;

  String? get m3uUrl {
    final u = _prefs.getString(_kM3uUrl);
    if (u == null || u.isEmpty) return null;
    return u;
  }

  XtreamCredentials? get credentials {
    final base = _prefs.getString(_kBaseUrl);
    final user = _prefs.getString(_kUsername);
    final pass = _prefs.getString(_kPassword);
    if (base == null ||
        base.isEmpty ||
        user == null ||
        user.isEmpty ||
        pass == null ||
        pass.isEmpty) {
      return null;
    }
    return XtreamCredentials(
      baseUrl: base,
      username: user,
      password: pass,
    );
  }

  Future<void> saveSession({
    required bool useDemo,
    XtreamCredentials? credentials,
    bool useM3u = false,
    String? m3uUrl,
  }) async {
    await _prefs.setBool(_kUseDemo, useDemo);
    await _prefs.setBool(_kUseM3u, useM3u);
    await _prefs.setBool(_kHasSession, true);
    if (credentials != null) {
      await _prefs.setString(_kBaseUrl, credentials.baseUrl);
      await _prefs.setString(_kUsername, credentials.username);
      await _prefs.setString(_kPassword, credentials.password);
    }
    if (m3uUrl != null && m3uUrl.isNotEmpty) {
      await _prefs.setString(_kM3uUrl, m3uUrl);
    }
  }

  Future<void> clearSession() async {
    await _prefs.remove(_kHasSession);
    await _prefs.remove(_kUseDemo);
    await _prefs.remove(_kUseM3u);
    await _prefs.remove(_kM3uUrl);
    await _prefs.remove(_kBaseUrl);
    await _prefs.remove(_kUsername);
    await _prefs.remove(_kPassword);
  }
}
