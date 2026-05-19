import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:google_sign_in/google_sign_in.dart';

class YTMusicCookieLoader extends StatefulWidget {
  final GoogleSignInAccount googleUser;
  final VoidCallback onCookiesLoaded;
  final VoidCallback onFailed;

  const YTMusicCookieLoader({
    super.key,
    required this.googleUser,
    required this.onCookiesLoaded,
    required this.onFailed,
  });

  @override
  State<YTMusicCookieLoader> createState() => _YTMusicCookieLoaderState();
}

class _YTMusicCookieLoaderState extends State<YTMusicCookieLoader> {
  bool _cookiesFetched = false;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1,
      height: 1, // Nearly invisible — just needs to exist to run
      child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('https://music.youtube.com')),
        initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          userAgent:
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
        ),
        onLoadStop: (controller, url) async {
          if (_cookiesFetched) return;

          // Wait for cookies to be set by YT Music
          await Future.delayed(const Duration(seconds: 2));

          final cookieManager = CookieManager.instance();
          final cookies = await cookieManager.getCookies(
            url: WebUri('https://music.youtube.com'),
          );

          final hasSapisid = cookies.any(
            (c) => c.name == 'SAPISID' || c.name == '__Secure-3PAPISID',
          );

          if (hasSapisid) {
            _cookiesFetched = true;
            widget.onCookiesLoaded();
          } else {
            widget.onFailed();
          }
        },
      ),
    );
  }
}
