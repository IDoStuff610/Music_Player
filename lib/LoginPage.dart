import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:music_player/MainHomePage.dart';
import 'package:music_player/system_setting/settings_page.dart';
import 'package:music_player/system_setting/config_service.dart';
import 'package:music_player/user_session.dart';
import 'package:music_player/services/ytmusic_webview_page.dart'; // <-- add this

GoogleSignIn? _googleSignIn;

class Loginpage extends StatefulWidget {
  const Loginpage({super.key});

  @override
  State<Loginpage> createState() => _LoginpageState();
}

class _LoginpageState extends State<Loginpage> {
  @override
  void initState() {
    super.initState();
    _initSignIn();
  }

  Future<void> _initSignIn() async {
    final clientId = await ConfigService.getClientId();
    _googleSignIn = GoogleSignIn(
      clientId: clientId,
      scopes: ['email', 'https://www.googleapis.com/auth/youtube'],
    );
    UserSession().googleSignIn = _googleSignIn;
    _trySilentSignIn();
  }

  Future<void> _trySilentSignIn() async {
    if (_googleSignIn == null) return;
    try {
      final account = await _googleSignIn!.signInSilently();
      if (account != null && mounted) {
        UserSession().user = account;
        // Already have cookies from last session? Skip WebView
        if (UserSession().ytMusicCookies != null) {
          _goToHome();
        } else {
          await _fetchCookiesThenGoHome();
        }
      }
    } catch (e) {
      debugPrint('Silent sign in error: $e');
    }
  }

  Future<void> _handleSignIn() async {
    if (_googleSignIn == null) return;
    try {
      final account = await _googleSignIn!.signIn();
      if (account != null && mounted) {
        UserSession().user = account;
        await _fetchCookiesThenGoHome();
      }
    } catch (e) {
      debugPrint('Sign in error: $e');
    }
  }

  Future<void> _fetchCookiesThenGoHome() async {
    if (!mounted) return;

    final cookies = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (context) => const YTMusicWebViewPage()),
    );

    if (cookies != null) {
      UserSession().ytMusicCookies = cookies;
    }

    UserSession().user ??= await _googleSignIn?.signInSilently();

    if (mounted) _goToHome();
  }

  void _goToHome() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const Mainhomepage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: _buildLoginButton()),
      appBar: _setting(),
    );
  }

  Widget _buildLoginButton() {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      icon: Image.asset(
        'assets/Dark_Mode_Google_Logo.png',
        height: 48,
        width: 48,
      ),
      onPressed: _handleSignIn,
      label: const Text("Sign in with Google"),
    );
  }

  AppBar _setting() {
    return AppBar(
      backgroundColor: Colors.black,
      actions: [
        IconButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => const SettingsPage()),
          ),
          icon: const Icon(Icons.settings, color: Colors.white),
        ),
      ],
    );
  }
}
