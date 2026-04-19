import 'package:flutter/material.dart';
import 'package:music_player/user_session.dart';

class Homepage extends StatefulWidget {
  const Homepage({super.key});

  @override
  State<Homepage> createState() => _HomepageState();
}

class _HomepageState extends State<Homepage> {
  final _user = UserSession();

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

  @override
  Widget build(BuildContext context) {
    final String? photoUrl = _user.photoUrl;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () => setState(() {
                _imageRetryCount = 0;
                _imageKey = UniqueKey();
              }),
              child: CircleAvatar(
                radius: 50,
                backgroundColor: Colors.grey,
                child: photoUrl != null
                    ? ClipOval(
                        child: Image.network(
                          photoUrl,
                          key: _imageKey,
                          width: 100,
                          height: 100,
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
                            return Text(
                              _user.displayName.isNotEmpty
                                  ? _user.displayName[0].toUpperCase()
                                  : '?',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 40,
                                fontWeight: FontWeight.bold,
                              ),
                            );
                          },
                        ),
                      )
                    : Text(
                        _user.displayName.isNotEmpty
                            ? _user.displayName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              _user.displayName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _user.email,
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
