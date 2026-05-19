import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:music_player/HomePage.dart';
import 'package:music_player/LoginPage.dart';
import 'package:music_player/user_session.dart';
import 'package:music_player/services/ytmusic_api_service.dart';
import 'package:music_player/services/ytmusic_auth_service.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

class _ThumbnailDebugPage extends StatefulWidget {
  const _ThumbnailDebugPage();

  @override
  State<_ThumbnailDebugPage> createState() => _ThumbnailDebugPageState();
}

class _ThumbnailDebugPageState extends State<_ThumbnailDebugPage> {
  final List<String> _logs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _test();
  }

  Future<void> _test() async {
    final cookies = UserSession().ytMusicCookies;
    if (cookies == null) {
      setState(() {
        _logs.add('❌ No cookies in session');
        _loading = false;
      });
      return;
    }

    try {
      final response = await http.post(
        Uri.parse(
          'https://music.youtube.com/youtubei/v1/browse?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Cookie': cookies,
          'Referer': 'https://music.youtube.com/',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15',
        },
        body: jsonEncode({
          "browseId": "FEmusic_home",
          "context": {
            "client": {
              "clientName": "WEB_REMIX",
              "clientVersion": "1.20240101.00.00",
              "hl": "en",
              "gl": "US",
            },
          },
        }),
      );

      final data = jsonDecode(response.body);

      // Drill into first shelf, first item
      final contents =
          data['contents']?['singleColumnBrowseResultsRenderer']?['tabs']?[0]?['tabRenderer']?['content']?['sectionListRenderer']?['contents']
              as List?;

      if (contents == null || contents.isEmpty) {
        setState(() {
          _logs.add('❌ No contents found in response');
          _loading = false;
        });
        return;
      }

      final firstShelf =
          contents.first['musicCarouselShelfRenderer'] ??
          contents.first['musicImmersiveCarouselShelfRenderer'];

      final firstItem = (firstShelf?['contents'] as List?)?.first;

      // Dump the raw JSON of the first item so we can see the thumbnail path
      final raw = const JsonEncoder.withIndent('  ').convert(firstItem);

      // Split into chunks of 200 chars so it fits on screen
      final chunks = <String>[];
      for (var i = 0; i < raw.length; i += 200) {
        chunks.add(
          raw.substring(i, i + 200 > raw.length ? raw.length : i + 200),
        );
      }

      setState(() {
        _logs.add('✅ Raw first item JSON:');
        _logs.addAll(chunks);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _logs.add('❌ Error: $e');
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text(
          'Thumbnail Debug',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy, color: Colors.white),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _logs.join('\n')));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copied to clipboard!')),
              );
            },
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Colors.white))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: _logs.length,
              itemBuilder: (context, index) {
                final line = _logs[index];
                Color color = Colors.grey;
                if (line.startsWith('📂')) color = Colors.amber;
                if (line.startsWith('  🔗')) color = Colors.lightBlueAccent;
                if (line.startsWith('❌')) color = Colors.redAccent;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    line,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                );
              },
            ),
    );
  }
}

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
      if (!UserSession().isLoggedIn && UserSession().ytMusicCookies == null) {
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
        // Add this to your actions list in _appbar()
        IconButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => const _ThumbnailDebugPage(),
            ),
          ),
          icon: const Icon(Icons.image_search, color: Colors.white),
        ),

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
              await UserSession().clear();
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
