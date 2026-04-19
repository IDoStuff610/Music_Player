import 'package:http/http.dart' as http;
import 'package:music_player/user_session.dart';

class YtmusicAuthService {
  static Future<String?> getYTMusicCookies() async {
    try {
      final googleUser = UserSession().googleSignIn?.currentUser;
      if (googleUser == null) return null;

      final auth = await googleUser.authentication;
      final accessToken = auth.accessToken;
      if (accessToken == null) return null;

      // collect all cookies from multiple requests
      final cookieMap = <String, String>{};

      // request 1 - youtube.com to get SAPISID, SSID, HSID
      final r1 = await http.get(
        Uri.parse('https://www.youtube.com'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
          'Accept': 'text/html',
        },
      );
      _parseCookies(r1.headers['set-cookie'], cookieMap);

      // request 2 - music.youtube.com to get music-specific cookies
      final r2 = await http.get(
        Uri.parse('https://music.youtube.com'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
          'Accept': 'text/html',
          'Cookie': cookieMap.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
        },
      );
      _parseCookies(r2.headers['set-cookie'], cookieMap);

      if (cookieMap.isEmpty) return null;

      final cookieString = cookieMap.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');

      UserSession().ytMusicCookies = cookieString;
      return cookieString;
    } catch (e) {
      return null;
    }
  }

  static void _parseCookies(String? raw, Map<String, String> map) {
    if (raw == null) return;
    for (final cookie in raw.split(',')) {
      final parts = cookie.trim().split(';')[0].split('=');
      if (parts.length >= 2) {
        map[parts[0].trim()] = parts.sublist(1).join('=').trim();
      }
    }
  }
}
