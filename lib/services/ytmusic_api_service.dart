import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ytmusic_auth_service.dart';

class YTMusicApiService {
  final YTMusicAuthService _auth;

  static const _baseUrl = 'https://music.youtube.com/youtubei/v1';
  static const _apiKey = 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30';

  static const _context = {
    "client": {
      "clientName": "WEB_REMIX",
      "clientVersion": "1.20240101.00.00",
      "hl": "en",
      "gl": "US",
    },
  };

  YTMusicApiService(this._auth);

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'Cookie': _auth.buildCookieHeader(),
    'Authorization': _auth.buildSapisidHash(),
    'X-Origin': 'https://music.youtube.com',
    'Referer': 'https://music.youtube.com/',
    'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
        'AppleWebKit/605.1.15',
  };

  // Fetches the full YT Music home page (Listen Again, Quick Picks, etc.)
  Future<List<MusicSection>> getHomeSections() async {
    final response = await http.post(
      Uri.parse('$_baseUrl/browse?key=$_apiKey'),
      headers: _headers,
      body: jsonEncode({
        "browseId": "FEmusic_home", // Home feed
        "context": _context,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to fetch home: ${response.statusCode}');
    }

    return _parseHomeSections(jsonDecode(response.body));
  }

  List<MusicSection> _parseHomeSections(Map<String, dynamic> json) {
    final sections = <MusicSection>[];

    try {
      // TEMP DEBUG - remove after fixing

      final contents =
          json['contents']['singleColumnBrowseResultsRenderer']['tabs'][0]['tabRenderer']['content']['sectionListRenderer']['contents']
              as List;

      for (final section in contents) {
        final shelf =
            section['musicCarouselShelfRenderer'] ??
            section['musicImmersiveCarouselShelfRenderer'];
        if (shelf == null) continue;

        final title = _extractText(
          shelf['header']?['musicCarouselShelfBasicHeaderRenderer']?['title'],
        );

        final items = <MusicItem>[];
        for (final item in (shelf['contents'] as List? ?? [])) {
          final parsed = _parseItem(item);
          if (parsed != null) items.add(parsed);
        }

        if (title != null && items.isNotEmpty) {
          sections.add(MusicSection(title: title, items: items));
        }

        // TEMP DEBUG - remove after fixing
        if (sections.isEmpty && contents.isNotEmpty) {
          final firstShelf =
              contents.first['musicCarouselShelfRenderer'] ??
              contents.first['musicImmersiveCarouselShelfRenderer'];
          if (firstShelf != null) {
            final firstItem = (firstShelf['contents'] as List?)?.first;
            print('RAW ITEM: $firstItem');
          }
        }
      }
    } catch (e) {
      // YT Music JSON structure can shift — log and continue
      print('Parse error: $e');
    }

    return sections;
  }

  MusicItem? _parseItem(Map<String, dynamic> item) {
    final renderer =
        item['musicTwoRowItemRenderer'] ??
        item['musicResponsiveListItemRenderer'];
    if (renderer == null) return null;

    final title = _extractText(renderer['title']);
    final subtitle = _extractText(renderer['subtitle']);

    String? thumbUrl;
    final thumbList =
        renderer['thumbnailRenderer']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'] ??
        renderer['thumbnail']?['musicThumbnailRenderer']?['thumbnail']?['thumbnails'];

    if (thumbList != null && thumbList is List && thumbList.isNotEmpty) {
      thumbUrl = thumbList.last['url'] as String?;
    }

    // Try to get videoId first, then fall back to playlistId
    final videoId = _extractVideoId(renderer);
    final playlistId = _extractPlaylistId(renderer);

    return MusicItem(
      title: title ?? 'Unknown',
      subtitle: subtitle,
      thumbnailUrl: thumbUrl,
      videoId: videoId,
      playlistId: playlistId,
    );
  }

  String? _extractText(dynamic textObj) {
    if (textObj == null) return null;
    final runs = textObj['runs'] as List?;
    if (runs != null && runs.isNotEmpty) {
      return runs.map((r) => r['text'] ?? '').join('');
    }
    return textObj['simpleText'] as String?;
  }

  String? _extractVideoId(Map<String, dynamic> renderer) {
    try {
      return renderer['thumbnailOverlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchEndpoint']?['videoId'];
    } catch (_) {}

    try {
      return renderer['navigationEndpoint']?['watchEndpoint']?['videoId'];
    } catch (_) {}

    return null;
  }

  String? _extractPlaylistId(Map<String, dynamic> renderer) {
    try {
      // From thumbnailOverlay play button
      return renderer['thumbnailOverlay']?['musicItemThumbnailOverlayRenderer']?['content']?['musicPlayButtonRenderer']?['playNavigationEndpoint']?['watchPlaylistEndpoint']?['playlistId'];
    } catch (_) {}

    try {
      // From navigation endpoint
      return renderer['navigationEndpoint']?['browseEndpoint']?['browseId'];
    } catch (_) {}

    return null;
  }
}

// --- Models ---

class MusicSection {
  final String title;
  final List<MusicItem> items;
  MusicSection({required this.title, required this.items});
}

class MusicItem {
  final String title;
  final String? subtitle;
  final String? thumbnailUrl;
  final String? videoId;
  final String? playlistId;

  MusicItem({
    required this.title,
    this.subtitle,
    this.thumbnailUrl,
    this.videoId,
    this.playlistId,
  });
}
