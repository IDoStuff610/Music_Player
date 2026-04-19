import 'package:http/http.dart' as http;
import 'package:music_player/user_session.dart';

class YtmusicAuthService {
  static Future<String?> getYTMusicCookies() async {
    try {
      final googleUser = UserSession().googleSignIn?.currentUser;
      if (googleUser == null) return null;

      // get the OAuth access token
      final auth = await googleUser.authentication;
      final accessToken = auth.accessToken;
      if (accessToken == null) return null;

      // make a request to YouTube Music with the access token
      final response = await http.get(
        Uri.parse('https://music.youtube.com'),
        headers: {
          'Authorization': 'Bearer $accessToken',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15',
        },
      );

      // extract cookies from response headers
      final rawCookies = response.headers['set-cookie'];
      if (rawCookies == null) return null;

      // parse and format cookies into a single string
      final cookieMap = <String, String>{};
      for (final cookie in rawCookies.split(',')) {
        final parts = cookie.trim().split(';')[0].split('=');
        if (parts.length >= 2) {
          cookieMap[parts[0].trim()] = parts.sublist(1).join('=').trim();
        }
      }

      if (cookieMap.isEmpty) return null;

      // save to session cache 👈 now inside the function
      UserSession().ytMusicCookies = cookieMap.entries
          .map((e) => '${e.key}=${e.value}')
          .join('; ');

      return UserSession().ytMusicCookies;
    } catch (e) {
      return null;
    }
  }
}
