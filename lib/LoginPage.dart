import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

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
  GoogleSignInAccount? _user;

  int _imageRetryCount = 0;
  static const int _maxRetries = 5;
  Key _imageKey = UniqueKey();

  void _retryImage() {
    if (_imageRetryCount < _maxRetries) {
      setState(() {
        _imageRetryCount++;
        _imageKey = UniqueKey();
      });
    }
  }

  Future<void> _handleSignIn() async {
    try {
      await _googleSignIn.signIn();
      setState(() {
        _user = _googleSignIn.currentUser;
        _imageRetryCount = 0;
        _imageKey = UniqueKey();
      });
    } catch (e) {
      debugPrint('Sign in errors: $e');
    }
  }

  Future<void> _handleSignOut() async {
    await _googleSignIn.signOut();
    setState(() => _user = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: _user == null ? _buildLoginButton() : _buildUserInfo(),
      ),
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

  Widget _buildUserInfo() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: () {
            setState(() {
              _imageRetryCount = 0;
              _imageKey = UniqueKey();
            });
          },
          child: CircleAvatar(
            radius: 40,
            backgroundColor: Colors.grey,
            child: _user!.photoUrl != null
                ? ClipOval(
                    child: Image.network(
                      _user!.photoUrl!,
                      key: _imageKey,
                      width: 80,
                      height: 80,
                      fit: BoxFit.cover,
                      errorBuilder: (context, error, stackTrace) {
                        if (_imageRetryCount < _maxRetries) {
                          Future.delayed(
                            const Duration(seconds: 2),
                            _retryImage,
                          );
                          return const CircularProgressIndicator(
                            color: Colors.white,
                          );
                        }
                        return const Icon(
                          Icons.person,
                          color: Colors.white,
                          size: 40,
                        );
                      },
                    ),
                  )
                : const Icon(Icons.person, color: Colors.white, size: 40),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          _user!.displayName ?? '',
          style: const TextStyle(color: Colors.white, fontSize: 20),
        ),
        Text(_user!.email, style: const TextStyle(color: Colors.grey)),
        const SizedBox(height: 24),
        TextButton(
          onPressed: _handleSignOut,
          child: const Text(
            'Sign Out',
            style: TextStyle(color: Colors.redAccent),
          ),
        ),
      ],
    );
  }
}
