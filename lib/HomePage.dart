import 'package:flutter/material.dart';
import 'package:dart_ytmusic_api/dart_ytmusic_api.dart';
import 'package:music_player/services/ytmusic_auth_service.dart';
import 'package:music_player/user_session.dart';

class Homepage extends StatefulWidget {
  const Homepage({super.key});

  @override
  State<Homepage> createState() => _HomepageState();
}

class _HomepageState extends State<Homepage> {
  final YTMusic _ytmusic = YTMusic();
  List<dynamic> _sections = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHome();
  }

  Future<void> _loadHome() async {
    try {
      final cookies =
          UserSession().ytMusicCookies ??
          await YtmusicAuthService.getYTMusicCookies();

      // temporarily show cookies on screen
      setState(() {
        _error = 'Cookies: $cookies';
        _isLoading = false;
      });
      return; // 👈 stops here, won't load music yet

      if (cookies != null) {
        await _ytmusic.initialize(cookies: cookies);
      } else {
        await _ytmusic.initialize();
      }

      final sections = await _ytmusic.getHomeSections();
      setState(() {
        _sections = sections;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  // Change the build method - remove the outer Scaffold, just return the body directly
  @override
  Widget build(BuildContext context) {
    return _isLoading
        ? const Center(child: CircularProgressIndicator(color: Colors.white))
        : _error != null
        ? Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
                const SizedBox(height: 12),
                Text(
                  _error!, // 👈 show actual error
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isLoading = true;
                      _error = null;
                    });
                    _loadHome();
                  },
                  child: const Text(
                    'Retry',
                    style: TextStyle(color: Colors.blueAccent),
                  ),
                ),
              ],
            ),
          )
        : RefreshIndicator(
            onRefresh: () async {
              setState(() => _isLoading = true);
              await _loadHome();
            },
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount: _sections.length,
              itemBuilder: (context, index) => _buildSection(_sections[index]),
            ),
          );
  }

  Widget _buildSection(dynamic section) {
    final String title = section.title ?? '';
    final List<dynamic> contents = section.contents ?? [];

    if (contents.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        SizedBox(
          height: 200,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: contents.length,
            itemBuilder: (context, index) {
              return _buildSongCard(contents[index]);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSongCard(dynamic item) {
    final String title = item.name ?? item.title ?? 'Unknown';
    final String subtitle =
        item.artist?.name ??
        (item.artists != null && item.artists.isNotEmpty
            ? item.artists[0].name
            : '');
    final String? thumbnailUrl =
        item.thumbnails != null && item.thumbnails.isNotEmpty
        ? item.thumbnails.last.url
        : null;

    return GestureDetector(
      onTap: () {},
      child: Container(
        width: 140,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadiusGeometry.circular(8),
              child: thumbnailUrl != null
                  ? Image.network(
                      thumbnailUrl,
                      width: 140,
                      height: 140,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _placeholderThumbnail(),
                    )
                  : _placeholderThumbnail(),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                style: const TextStyle(color: Colors.grey, fontSize: 11),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }

  Widget _placeholderThumbnail() {
    return Container(
      width: 140,
      height: 140,
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.music_note, color: Colors.grey, size: 40),
    );
  }
}
