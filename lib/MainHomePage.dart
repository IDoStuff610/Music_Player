import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:music_player/HomePage.dart';
import 'package:music_player/LoginPage.dart';
import 'package:music_player/user_session.dart';

class Mainhomepage extends StatefulWidget {
  const Mainhomepage({super.key});

  @override
  State<Mainhomepage> createState() => _MainhomepageState();
}

class _MainhomepageState extends State<Mainhomepage> {
  bool _showDebug = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!UserSession().isLoggedIn) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => const Loginpage()),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _appbar(),
      body: Column(
        children: [
          // Debug panel slides in when toggled
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: _showDebug ? 260 : 0,
            child: _showDebug ? _buildDebugPanel() : const SizedBox.shrink(),
          ),
          const Expanded(child: Homepage()),
        ],
      ),
      drawer: _buildDrawer(),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildDebugPanel() {
    final cookies = UserSession().ytMusicCookies;
    final lines = cookies?.split('; ') ?? [];

    // Highlight important cookies
    final importantKeys = [
      'SAPISID',
      '__Secure-3PAPISID',
      'SID',
      'HSID',
      'APISID',
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: cookies != null ? Colors.greenAccent.shade700 : Colors.red,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                cookies != null
                    ? '✅ Cookies loaded (${lines.length} found)'
                    : '❌ No cookies',
                style: TextStyle(
                  color: cookies != null
                      ? Colors.greenAccent
                      : Colors.redAccent,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // Copy all cookies button
              if (cookies != null)
                GestureDetector(
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: cookies));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cookies copied to clipboard!'),
                        duration: Duration(seconds: 2),
                      ),
                    );
                  },
                  child: const Row(
                    children: [
                      Icon(Icons.copy, color: Colors.grey, size: 12),
                      SizedBox(width: 4),
                      Text(
                        'Copy all',
                        style: TextStyle(color: Colors.grey, fontSize: 11),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const Divider(color: Colors.grey, height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: cookies == null
                  ? const Text(
                      'No cookies in session.\nTry logging out and back in.',
                      style: TextStyle(color: Colors.grey, fontSize: 11),
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: lines.map((line) {
                        final key = line.split('=').first;
                        final isImportant = importantKeys.contains(key);
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 3),
                          child: RichText(
                            text: TextSpan(
                              children: [
                                TextSpan(
                                  text: '$key=',
                                  style: TextStyle(
                                    color: isImportant
                                        ? Colors.amber
                                        : Colors.grey,
                                    fontSize: 10,
                                    fontWeight: isImportant
                                        ? FontWeight.bold
                                        : FontWeight.normal,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                TextSpan(
                                  text: line.substring(key.length + 1),
                                  style: TextStyle(
                                    color: isImportant
                                        ? Colors.greenAccent
                                        : Colors.grey.shade600,
                                    fontSize: 10,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      }).toList(),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  AppBar _appbar() {
    return AppBar(
      backgroundColor: Colors.black,
      leading: Builder(
        builder: (context) => IconButton(
          onPressed: () => Scaffold.of(context).openDrawer(),
          icon: const Icon(Icons.menu, color: Colors.white),
        ),
      ),
      actions: [
        // 🍪 Debug toggle button
        IconButton(
          onPressed: () => setState(() => _showDebug = !_showDebug),
          icon: Text(
            '🍪',
            style: TextStyle(
              fontSize: 20,
              color: _showDebug ? Colors.amber : Colors.white,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDrawer() {
    return Drawer(
      backgroundColor: const Color.fromARGB(255, 22, 22, 22),
      child: ListView(
        children: [
          UserAccountsDrawerHeader(
            decoration: BoxDecoration(color: Colors.grey.shade900),
            accountName: Text(
              UserSession().displayName,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
            accountEmail: Text(
              UserSession().email,
              style: const TextStyle(color: Colors.grey),
            ),
            currentAccountPicture: Builder(
              builder: (context) {
                final String? photoUrl = UserSession().photoUrl;
                return CircleAvatar(
                  backgroundColor: Colors.grey,
                  backgroundImage: photoUrl != null
                      ? NetworkImage(photoUrl)
                      : null,
                  child: photoUrl == null
                      ? Text(
                          UserSession().displayName.isNotEmpty
                              ? UserSession().displayName[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            fontSize: 30,
                            color: Colors.white,
                          ),
                        )
                      : null,
                );
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.person_2_outlined, color: Colors.grey),
            title: const Text("Account", style: TextStyle(color: Colors.grey)),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.settings, color: Colors.grey),
            title: const Text("Setting", style: TextStyle(color: Colors.grey)),
            onTap: () {},
          ),
          ListTile(
            leading: const Icon(Icons.logout_outlined, color: Colors.redAccent),
            title: const Text(
              "Log Out",
              style: TextStyle(color: Colors.redAccent),
            ),
            onTap: () async {
              await UserSession().googleSignIn?.signOut();
              UserSession().clear();
              if (mounted) {
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => const Loginpage()),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNav() {
    return BottomNavigationBar(
      selectedItemColor: Colors.white,
      unselectedItemColor: Colors.grey,
      backgroundColor: Colors.grey.shade900,
      type: BottomNavigationBarType.fixed,
      items: const [
        BottomNavigationBarItem(icon: Icon(Icons.home_filled), label: 'Home'),
        BottomNavigationBarItem(
          icon: Icon(Icons.library_music_outlined),
          label: 'Library',
        ),
        BottomNavigationBarItem(
          icon: Icon(Icons.download_rounded),
          label: 'Download',
        ),
      ],
    );
  }
}
