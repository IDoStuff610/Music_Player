import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:music_player/HomePage.dart';
import 'package:music_player/user_session.dart';

final GoogleSignIn _googleSignIn = GoogleSignIn(
  clientId:
      '27032719106-co024attcbtvpd3hfbk6860t9ndao9lu.apps.googleusercontent.com',
  scopes: ['email'],
);

class Loginpage extends StatefulWidget {
  const Loginpage({super.key});

  @override
  State<Loginpage> createState() => _LoginpageState();
}

class _LoginpageState extends State<Loginpage> {
  @override
  void initState() {
    super.initState();
    _trySilentSignIn();
  }

  Future<void> _trySilentSignIn() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account != null && mounted) {
        UserSession().user = account;
        _goToHome();
      }
    } catch (e) {
      debugPrint('Silent sign in error: $e');
    }
  }

  void _goToHome() {
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const Homepage()),
    );
  }

  Future<void> _handleSignIn() async {
    try {
      await _googleSignIn.signIn();
      if (_googleSignIn.currentUser != null && mounted) {
        UserSession().user = _googleSignIn.currentUser;
        _goToHome();
      }
    } catch (e) {
      debugPrint('Sign in errors: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(child: _buildLoginButton()),
    );
  }

  Widget _buildLoginButton() {
    return ElevatedButton.icon(
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
      icon: const Text(
        'G',
        style: TextStyle(
          color: Color(0xFF4285F4),
          fontSize: 22,
          fontWeight: FontWeight.bold,
        ),
      ),
      onPressed: _handleSignIn,
      label: const Text("Sign in with Google"),
    );
  }
}
