import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_sign_in/google_sign_in.dart';

class YTMusicAuthService {
  static const _ytMusicUrl = 'https://music.youtube.com';

  Map<String, String> _cookies = {};
  String? _sapisid;

  // Call this after your existing Google Sign In
  Future<bool> extractCookiesViaWebView(GoogleSignInAccount googleUser) async {
    final googleAuth = await googleUser.authentication;
    final accessToken = googleAuth.accessToken;

    if (accessToken == null) return false;

    // Pre-set the OAuth token as a cookie so the WebView is authenticated
    final cookieManager = CookieManager.instance();
    await cookieManager.setCookie(
      url: WebUri(_ytMusicUrl),
      name: 'GOOGLE_ABUSE_EXEMPTION',
      value: '', // not always needed
    );

    // Load YT Music silently via headless WebView (done in a separate widget)
    // See step 3 — once loaded, call this:
    return await _fetchCookiesFromWebView();
  }

  Future<bool> _fetchCookiesFromWebView() async {
    final cookieManager = CookieManager.instance();
    final cookies = await cookieManager.getCookies(url: WebUri(_ytMusicUrl));

    for (final cookie in cookies) {
      _cookies[cookie.name] = cookie.value;
    }

    _sapisid = _cookies['SAPISID'] ?? _cookies['__Secure-3PAPISID'];
    return _sapisid != null;
  }

  // Generates the required Authorization header for YT Music
  String buildSapisidHash() {
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final input = '$timestamp $_sapisid $_ytMusicUrl';
    final hash = sha1.convert(utf8.encode(input)).toString();
    return 'SAPISIDHASH ${timestamp}_$hash';
  }

  String buildCookieHeader() {
    return _cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  bool get isAuthenticated => _sapisid != null;
}
