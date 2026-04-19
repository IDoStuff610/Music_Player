import 'package:google_sign_in/google_sign_in.dart';

class UserSession {
  static final UserSession _instance = UserSession._internal();
  factory UserSession() => _instance;
  UserSession._internal();

  GoogleSignInAccount? user;
  GoogleSignIn? googleSignIn;

  String get displayName => user?.displayName ?? '';
  String get email => user?.email ?? '';
  String get photoUrl => user?.photoUrl ?? '';
  String? ytMusicCookies;

  bool get isLoggedIn => user != null;

  void clear() {
    user = null;
    googleSignIn = null;
  }
}
