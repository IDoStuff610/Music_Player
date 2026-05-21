import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:music_player/services/ytmusic_api_service.dart';
import 'package:music_player/services/ytmusic_auth_service.dart';
import 'package:music_player/user_session.dart';
import 'package:path_provider/path_provider.dart';

// youtube_explode_dart is no longer needed — removed to fix rate limiting

class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();

  MusicItem? currentItem;
  bool isLoading = false;
  String? error;
  String? debugInfo;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  bool get isPlaying => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;

  Future<void> play(MusicItem item) async {
    if (item.videoId == null && item.playlistId == null) {
      error = 'No video ID or playlist ID';
      notifyListeners();
      return;
    }

    isLoading = true;
    error = null;
    debugInfo = null;
    currentItem = item;
    notifyListeners();

    try {
      final videoId =
          item.videoId ?? await _resolveVideoIdFromPlaylist(item.playlistId!);

      if (videoId == null) {
        error = 'Could not resolve a video ID';
        isLoading = false;
        notifyListeners();
        return;
      }

      // Use InnerTube player API directly — no more youtube_explode_dart
      final streamUrl = await _getStreamUrlFromInnertube(videoId);

      if (streamUrl == null) {
        error = 'Could not get stream URL from InnerTube';
        isLoading = false;
        notifyListeners();
        return;
      }

      debugInfo = '✅ Got stream URL via InnerTube';
      notifyListeners();

      // Download to temp so AVPlayer doesn't re-request the URL (avoids 403)
      final tempFile = await _downloadStreamToTemp(videoId, streamUrl);

      if (tempFile == null) {
        error = 'Could not download stream';
        isLoading = false;
        notifyListeners();
        return;
      }

      await _player.setAudioSource(
        AudioSource.file(
          tempFile.path,
          tag: MediaItem(
            id: videoId,
            title: item.title,
            artist: item.subtitle ?? '',
            artUri: item.thumbnailUrl != null
                ? Uri.parse(item.thumbnailUrl!)
                : null,
          ),
        ),
      );

      await _player.play();
    } catch (e) {
      error = e.toString();
      debugInfo = (debugInfo ?? '') + '\nOuter error: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Calls the YouTube Music InnerTube /player endpoint using the user's
  /// existing YT Music cookies. Uses the WEB_REMIX client — the same client
  /// the cookies were issued for — so there are no auth mismatches and no
  /// rate limiting from anonymous scraping.
  ///
  /// Falls back to the ANDROID_MUSIC client if WEB_REMIX returns no URLs,
  /// since Android clients return unsigned direct URLs on some videos.
  Future<String?> _getStreamUrlFromInnertube(String videoId) async {
    final auth = _getAuth();
    if (auth == null) {
      debugInfo = 'No auth cookies available';
      notifyListeners();
      return null;
    }

    // Try clients in order of preference
    final clients = [
      _ClientConfig(
        name: 'WEB_REMIX',
        version: '1.20240101.00.00',
        baseUrl: 'https://music.youtube.com',
        // key is the same one already used for browse calls
        apiKey: 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
        clientNameHeader: '67',
        userAgent:
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5_1 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
            'Mobile/15E148 Safari/604.1',
      ),
      _ClientConfig(
        name: 'ANDROID_MUSIC',
        version: '7.27.52',
        baseUrl: 'https://music.youtube.com',
        apiKey: 'AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
        clientNameHeader: '21',
        userAgent:
            'com.google.android.apps.youtube.music/7.27.52 (Linux; U; '
            'Android 14; Pixel 8 Build/UP1A.231005.007) gzip',
        extraContext: {
          'androidSdkVersion': 34,
          'osName': 'Android',
          'osVersion': '14',
        },
      ),
    ];

    for (final client in clients) {
      debugInfo = 'Trying ${client.name} client...';
      notifyListeners();

      try {
        final url = await _tryClient(videoId, auth, client);
        if (url != null) return url;
      } catch (e) {
        debugInfo = '${client.name} error: $e';
        notifyListeners();
      }
    }

    debugInfo = 'All InnerTube clients failed';
    notifyListeners();
    return null;
  }

  Future<String?> _tryClient(
    String videoId,
    YTMusicAuthService auth,
    _ClientConfig client,
  ) async {
    final response = await http.post(
      Uri.parse(
        '${client.baseUrl}/youtubei/v1/player'
        '?key=${client.apiKey}&prettyPrint=false',
      ),
      headers: {
        'Content-Type': 'application/json',
        'Cookie': auth.buildCookieHeader(),
        'Authorization': auth.buildSapisidHash(),
        'X-Origin': client.baseUrl,
        'Origin': client.baseUrl,
        'Referer': '${client.baseUrl}/',
        'User-Agent': client.userAgent,
        'X-Youtube-Client-Name': client.clientNameHeader,
        'X-Youtube-Client-Version': client.version,
      },
      body: jsonEncode({
        'videoId': videoId,
        'contentCheckOk': true,
        'racyCheckOk': true,
        'context': {
          'client': {
            'clientName': client.name,
            'clientVersion': client.version,
            'hl': 'en',
            'gl': 'US',
            ...?client.extraContext,
          },
        },
      }),
    );

    if (response.statusCode != 200) {
      debugInfo = '${client.name} returned ${response.statusCode}';
      notifyListeners();
      return null;
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    final status = json['playabilityStatus']?['status'] as String?;
    if (status != null && status != 'OK') {
      final reason = json['playabilityStatus']?['reason'] ?? 'Unknown';
      debugInfo = '${client.name} not playable: $status — $reason';
      notifyListeners();
      return null;
    }

    final adaptiveFormats =
        json['streamingData']?['adaptiveFormats'] as List? ?? [];
    final regularFormats = json['streamingData']?['formats'] as List? ?? [];

    final allAudio = <Map<String, dynamic>>[];

    // Prefer adaptive (audio-only) streams
    for (final f in adaptiveFormats) {
      final mime = (f as Map<String, dynamic>)['mimeType']?.toString() ?? '';
      if (mime.contains('audio')) allAudio.add(f);
    }

    // Fall back to muxed formats
    if (allAudio.isEmpty) {
      for (final f in regularFormats) {
        allAudio.add(f as Map<String, dynamic>);
      }
    }

    if (allAudio.isEmpty) {
      debugInfo = '${client.name}: no audio formats in response';
      notifyListeners();
      return null;
    }

    // Sort highest bitrate first
    allAudio.sort((a, b) {
      final aBr = (a['bitrate'] as num?)?.toInt() ?? 0;
      final bBr = (b['bitrate'] as num?)?.toInt() ?? 0;
      return bBr.compareTo(aBr);
    });

    // Prefer AAC-LC (mp4a.40.2) — natively supported on iOS AVPlayer
    final m4a = allAudio.where((f) {
      final mime = f['mimeType']?.toString() ?? '';
      return mime.contains('mp4a.40.2') || mime.contains('audio/mp4');
    }).toList();

    final chosen = m4a.isNotEmpty ? m4a.first : allAudio.first;
    final streamUrl = chosen['url'] as String?;

    if (streamUrl == null) {
      debugInfo = '${client.name}: stream URL is null (may need cipher)';
      notifyListeners();
      return null;
    }

    final bitrate = chosen['bitrate'];
    final mime = chosen['mimeType'];
    debugInfo = '✅ ${client.name}: $bitrate bps | $mime';
    notifyListeners();

    return streamUrl;
  }

  /// Downloads the stream to a temp file using our own authenticated HTTP
  /// client. The signed URL from InnerTube is tied to this IP, so we fetch
  /// it ourselves rather than letting AVPlayer open it fresh (which can 403).
  Future<File?> _downloadStreamToTemp(String videoId, String streamUrl) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/yt_audio_$videoId.mp4');

      // Return cached file if available
      if (await file.exists()) {
        debugInfo = '✅ Using cached file\n$debugInfo';
        notifyListeners();
        return file;
      }

      debugInfo = 'Downloading stream...\n$debugInfo';
      notifyListeners();

      // Fetch the stream using plain http — no special auth needed,
      // the URL itself is signed by YouTube for this IP
      final request = http.Request('GET', Uri.parse(streamUrl));
      final streamedResponse = await request.send();

      if (streamedResponse.statusCode != 200) {
        debugInfo =
            'Stream download failed: ${streamedResponse.statusCode}\n$debugInfo';
        notifyListeners();
        return null;
      }

      final output = file.openWrite();
      await streamedResponse.stream.pipe(output);
      await output.flush();
      await output.close();

      final fileSize = await file.length();
      debugInfo =
          '✅ Downloaded ${(fileSize / 1024).toStringAsFixed(1)} KB\n$debugInfo';
      notifyListeners();

      return file;
    } catch (e) {
      debugInfo = 'Download error: $e\n$debugInfo';
      notifyListeners();
      return null;
    }
  }

  Future<String?> _resolveVideoIdFromPlaylist(String playlistId) async {
    final auth = _getAuth();
    if (auth == null) return null;

    try {
      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/next'),
        headers: {
          'Content-Type': 'application/json',
          'Cookie': auth.buildCookieHeader(),
          'Authorization': auth.buildSapisidHash(),
          'X-Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
        },
        body: jsonEncode({
          'playlistId': playlistId,
          'context': {
            'client': {
              'clientName': 'WEB_REMIX',
              'clientVersion': '1.20240101.00.00',
              'hl': 'en',
              'gl': 'US',
            },
          },
        }),
      );

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body);
      return json['currentVideoEndpoint']?['watchEndpoint']?['videoId'];
    } catch (_) {
      return null;
    }
  }

  YTMusicAuthService? _getAuth() {
    final cookies = UserSession().ytMusicCookies;
    if (cookies == null) return null;
    return YTMusicAuthService.fromCookieString(cookies);
  }

  /// Clears cached audio files
  Future<void> clearCache() async {
    try {
      final dir = await getTemporaryDirectory();
      final files = dir.listSync().whereType<File>().where(
        (f) => f.path.contains('yt_audio_'),
      );
      for (final f in files) {
        await f.delete();
      }
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    if (_player.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
    notifyListeners();
  }

  Future<void> seekTo(Duration position) async {
    await _player.seek(position);
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

/// Describes an InnerTube client configuration to try for stream URL extraction
class _ClientConfig {
  final String name;
  final String version;
  final String baseUrl;
  final String apiKey;
  final String clientNameHeader;
  final String userAgent;
  final Map<String, dynamic>? extraContext;

  const _ClientConfig({
    required this.name,
    required this.version,
    required this.baseUrl,
    required this.apiKey,
    required this.clientNameHeader,
    required this.userAgent,
    this.extraContext,
  });
}
