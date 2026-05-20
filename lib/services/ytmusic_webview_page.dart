import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:music_player/user_session.dart';

class YTMusicWebViewPage extends StatefulWidget {
  const YTMusicWebViewPage({super.key});

  @override
  State<YTMusicWebViewPage> createState() => _YTMusicWebViewPageState();
}

class _YTMusicWebViewPageState extends State<YTMusicWebViewPage> {
  InAppWebViewController? _webViewController;
  String _status = 'Signing into Google...';
  bool _redirectedToMusic = false;

  // After Google login completes, redirect to YT Music
  Future<void> _redirectToYTMusic() async {
    if (_redirectedToMusic) return;
    _redirectedToMusic = true;
    setState(() => _status = 'Redirecting to YouTube Music...');
    await _webViewController?.loadUrl(
      urlRequest: URLRequest(url: WebUri('https://music.youtube.com')),
    );
  }

  Future<void> _extractCookies() async {
    final cookieManager = CookieManager.instance();

    while (mounted) {
      setState(() => _status = 'Waiting for cookies...');
      await Future.delayed(const Duration(seconds: 1));

      final cookies = await cookieManager.getCookies(
        url: WebUri('https://music.youtube.com'),
      );

      final hasSapisid = cookies.any(
        (c) => c.name == 'SAPISID' || c.name == '__Secure-3PAPISID',
      );

      if (hasSapisid) {
        final cookieString = cookies
            .map((c) => '${c.name}=${c.value}')
            .join('; ');
        setState(() => _status = '✅ Got ${cookies.length} cookies!');
        await Future.delayed(const Duration(milliseconds: 500));
        if (mounted) Navigator.pop(context, cookieString);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final email = UserSession().email;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          _status,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Skip', style: TextStyle(color: Colors.grey)),
          ),
        ],
      ),
      body: InAppWebView(
        // Load Google sign-in pre-filled with the user's email
        initialUrlRequest: URLRequest(
          url: WebUri(
            'https://accounts.google.com/ServiceLogin'
            '?service=youtube'
            '&continue=https://music.youtube.com'
            '&Email=${Uri.encodeComponent(email)}',
          ),
        ),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          userAgent:
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
              'Mobile/15E148 Safari/604.1',
        ),
        onWebViewCreated: (controller) {
          _webViewController = controller;
        },
        onLoadStop: (controller, url) async {
          final urlStr = url.toString();
          setState(() => _status = 'Page: $urlStr');

          // Once we land on YT Music, grab cookies
          if (urlStr.contains('music.youtube.com')) {
            await _extractCookies();
          }
          // If Google login completed (no longer on accounts.google.com)
          else if (!urlStr.contains('accounts.google.com') &&
              urlStr.contains('youtube.com')) {
            await _redirectToYTMusic();
          }
        },
      ),
    );
  }
}
