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

      final cookieMap = <String, String>{};

      // use accounts.google.com to get full session cookies
      final r1 = await http.get(
        Uri.parse(
          'https://accounts.google.com/o/oauth2/auth?client_id=770336754352-r8dl0o1v5bpjl88de4g4lh1i4tlt1hgh.apps.googleusercontent.com&response_type=permission&scope=https://www.googleapis.com/auth/youtube',
        ),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
        },
      );
      _parseCookies(r1.headers['set-cookie'], cookieMap);

      // then hit youtube.com with those cookies
      final r2 = await http.get(
        Uri.parse('https://www.youtube.com/'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Cookie': cookieMap.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
        },
      );
      _parseCookies(r2.headers['set-cookie'], cookieMap);

      // finally hit music.youtube.com
      final r3 = await http.get(
        Uri.parse('https://music.youtube.com/'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'Cookie': cookieMap.entries
              .map((e) => '${e.key}=${e.value}')
              .join('; '),
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
        },
      );
      _parseCookies(r3.headers['set-cookie'], cookieMap);

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
