import 'package:flutter/material.dart';
import 'package:music_player/services/ytmusic_api_service.dart';
import 'package:music_player/services/ytmusic_auth_service.dart';
import 'package:music_player/user_session.dart';
import 'package:music_player/services/audio_player_service.dart';

class Homepage extends StatefulWidget {
  const Homepage({super.key});

  @override
  State<Homepage> createState() => _HomepageState();
}

class _HomepageState extends State<Homepage> {
  List<MusicSection> _sections = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadHome();
  }

  Future<void> _loadHome() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final String? cookies = UserSession().ytMusicCookies;

      if (cookies == null) {
        setState(() {
          _error = 'No cookies found. Please log out and log back in.';
          _isLoading = false;
        });
        return;
      }

      // Build the auth service from the stored cookie string
      final auth = YTMusicAuthService.fromCookieString(cookies);

      if (!auth.isAuthenticated) {
        setState(() {
          _error = 'SAPISID not found in cookies. Try logging out and back in.';
          _isLoading = false;
        });
        return;
      }

      final api = YTMusicApiService(auth);
      final sections = await api.getHomeSections();

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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 48),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 12),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _loadHome,
              child: const Text(
                'Retry',
                style: TextStyle(color: Colors.blueAccent),
              ),
            ),
          ],
        ),
      );
    }

    if (_sections.isEmpty) {
      return const Center(
        child: Text('No sections found.', style: TextStyle(color: Colors.grey)),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadHome,
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 16),
        itemCount: _sections.length,
        itemBuilder: (context, index) => _buildSection(_sections[index]),
      ),
    );
  }

  Widget _buildSection(MusicSection section) {
    if (section.items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            section.title,
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
            itemCount: section.items.length,
            itemBuilder: (context, index) =>
                _buildSongCard(section.items[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildSongCard(MusicItem item) {
    return GestureDetector(
      onTap: () {
        // playback coming next!
        AudioPlayerService().play(item);
      },
      child: Container(
        width: 140,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: item.thumbnailUrl != null
                  ? Image.network(
                      item.thumbnailUrl!,
                      width: 140,
                      height: 140,
                      fit: BoxFit.cover,
                      headers: {
                        'Cookie': UserSession().ytMusicCookies ?? '',
                        'Referer': 'https://music.youtube.com/',
                      },
                      errorBuilder: (context, error, stackTrace) {
                        debugPrint('Thumbnail error for ${item.title}: $error');
                        return _placeholderThumbnail();
                      },
                      loadingBuilder: (context, child, loadingProgress) {
                        if (loadingProgress == null) return child;
                        return Container(
                          width: 140,
                          height: 140,
                          color: Colors.grey.shade800,
                          child: const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white54,
                              strokeWidth: 2,
                            ),
                          ),
                        );
                      },
                    )
                  : _placeholderThumbnail(),
            ),
            const SizedBox(height: 6),
            Text(
              item.title,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (item.subtitle != null && item.subtitle!.isNotEmpty)
              Text(
                item.subtitle!,
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
