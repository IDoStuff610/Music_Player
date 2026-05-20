import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:music_player/services/ytmusic_api_service.dart';
import 'package:music_player/services/ytmusic_auth_service.dart';
import 'package:music_player/user_session.dart';

class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();

  MusicItem? currentItem;
  bool isLoading = false;
  String? error;

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

      final streamUrl = await _fetchStreamUrl(videoId);

      if (streamUrl == null) {
        error = 'Could not get stream URL';
        isLoading = false;
        notifyListeners();
        return;
      }

      final auth = _getAuth();
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(streamUrl),
          headers: auth != null
              ? {
                  'Cookie': auth.buildCookieHeader(),
                  'Referer': 'https://music.youtube.com/',
                  'Origin': 'https://music.youtube.com',
                }
              : {},
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
      debugPrint('🔴 AudioPlayerService error: $e');
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  /// Calls the YT Music internal /player endpoint to get a direct stream URL.
  /// This is the same API YT Music web uses — no third-party library needed.
  Future<String?> _fetchStreamUrl(String videoId) async {
    final auth = _getAuth();

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Referer': 'https://music.youtube.com/',
      'Origin': 'https://music.youtube.com',
      'X-Origin': 'https://music.youtube.com',
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
          'AppleWebKit/605.1.15',
    };

    if (auth != null) {
      headers['Cookie'] = auth.buildCookieHeader();
      headers['Authorization'] = auth.buildSapisidHash();
    }

    final body = jsonEncode({
      'videoId': videoId,
      'context': {
        'client': {
          'clientName': 'WEB_REMIX',
          'clientVersion': '1.20240101.00.00',
          'hl': 'en',
          'gl': 'US',
        },
      },
      'playbackContext': {
        'contentPlaybackContext': {
          'signatureTimestamp': 19950, // safe static value for web client
        },
      },
    });

    final response = await http.post(
      Uri.parse(
        'https://music.youtube.com/youtubei/v1/player'
        '?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
      ),
      headers: headers,
      body: body,
    );

    if (response.statusCode != 200) {
      debugPrint('🔴 Player API error: ${response.statusCode}');
      debugPrint(response.body);
      return null;
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;

    // Pick the best audio-only format
    final formats = (json['streamingData']?['adaptiveFormats'] as List?)
        ?.where(
          (f) =>
              (f['mimeType'] as String?)?.startsWith('audio/') == true &&
              f['url'] != null,
        )
        .toList();

    if (formats == null || formats.isEmpty) {
      debugPrint('🔴 No audio formats found in player response');
      return null;
    }

    // Sort by bitrate descending, pick highest
    formats.sort(
      (a, b) => ((b['averageBitrate'] ?? 0) as int).compareTo(
        (a['averageBitrate'] ?? 0) as int,
      ),
    );

    final url = formats.first['url'] as String;
    debugPrint('✅ Stream URL resolved for $videoId');
    return url;
  }

  Future<String?> _resolveVideoIdFromPlaylist(String playlistId) async {
    final auth = _getAuth();
    if (auth == null) return null;

    final response = await http.post(
      Uri.parse(
        'https://music.youtube.com/youtubei/v1/next'
        '?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30',
      ),
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

    try {
      final json = jsonDecode(response.body);
      // First video in the playlist queue
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
