import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:music_player/user_session.dart';

class YTMusicWebViewPage extends StatefulWidget {
  const YTMusicWebViewPage({super.key});

  @override
  State<YTMusicWebViewPage> createState() => _YTMusicWebViewPageState();
}

class _YTMusicWebViewPageState extends State<YTMusicWebViewPage> {
  bool _cookiesCaptured = false;

  Future<void> _checkCookies() async {
    if (_cookiesCaptured) return;

    final cookieManager = CookieManager.instance();
    final url = WebUri('https://music.youtube.com');

    final cookies = await cookieManager.getCookies(url: url);

    // temporarily capture everything
    if (cookies.isNotEmpty) {
      final cookieString = cookies
          .map((c) => '${c.name}=${c.value}')
          .join('; ');

      UserSession().ytMusicCookies = cookieString;
      _cookiesCaptured = true;

      if (mounted) {
        Navigator.pop(context, cookieString);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          'Sign in to YouTube Music',
          style: TextStyle(color: Colors.white),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('https://music.youtube.com')),
        initialSettings: InAppWebViewSettings(
          userAgent:
              'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1',
          javaScriptEnabled: true,
        ),
        onLoadStop: (controller, url) async {
          await _checkCookies();
        },
        onPageCommitVisible: (controller, url) async {
          await _checkCookies();
        },
      ),
    );
  }
}
