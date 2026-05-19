import 'package:google_sign_in/google_sign_in.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class UserSession {
  static final UserSession _instance = UserSession._internal();
  factory UserSession() => _instance;
  UserSession._internal();

  static const _storage = FlutterSecureStorage();
  static const _cookieKey = 'yt_music_cookies';

  GoogleSignInAccount? user;
  GoogleSignIn? googleSignIn;

  String get displayName => user?.displayName ?? '';
  String get email => user?.email ?? '';
  String get photoUrl => user?.photoUrl ?? '';
  String? ytMusicCookies;

  bool get isLoggedIn => user != null;

  Future<void> loadSavedCookies() async {
    ytMusicCookies = await _storage.read(key: _cookieKey);
  }

  // Call this whenever you set new cookies
  Future<void> saveCookies(String cookies) async {
    ytMusicCookies = cookies;
    await _storage.write(key: _cookieKey, value: cookies);
  }

  Future<void> clear() async {
    user = null;
    googleSignIn = null;
    ytMusicCookies = null;
    await _storage.delete(key: _cookieKey);
  }
}
