import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ConfigService {
  static const _webKey = 'web_client_id';
  static const _iosKey = 'ios_client_id';

  static const _defaultWeb =
      '27032719106-co024attcbtvpd3hfbk6860t9ndao9lu.apps.googleusercontent.com';
  static const _defaultIos =
      '27032719106-784n1s2hl2qtfpbfkam2vm620akug97g.apps.googleusercontent.com';

  static Future<String> getClientId() async {
    final prefs = await SharedPreferences.getInstance();
    if (kIsWeb) {
      return prefs.getString(_webKey) ?? _defaultWeb;
    }
    return prefs.getString(_iosKey) ?? _defaultIos;
  }

  static Future<void> saveClientIds({
    required String webId,
    required String iosId,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_webKey, webId);
    await prefs.setString(_iosKey, iosId);
  }
}
