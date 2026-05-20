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
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<String?> _fetchStreamUrl(String videoId) async {
    final auth = _getAuth();

    if (auth == null) {
      debugInfo = 'auth is null — no cookies found';
      notifyListeners();
      return null;
    }

    // No API key in URL — use Authorization header only
    final uri = Uri.parse('https://music.youtube.com/youtubei/v1/player');

    final headers = <String, String>{
      'Content-Type': 'application/json',
      'Cookie': auth.buildCookieHeader(),
      'Authorization': auth.buildSapisidHash(),
      'X-Origin': 'https://music.youtube.com',
      'Referer': 'https://music.youtube.com/',
      'Origin': 'https://music.youtube.com',
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
          'AppleWebKit/537.36 (KHTML, like Gecko) '
          'Chrome/120.0.0.0 Safari/537.36',
      'X-Youtube-Client-Name': '67', // 67 = WEB_REMIX
      'X-Youtube-Client-Version': '1.20240101.00.00',
    };

    final body = jsonEncode({
      'videoId': videoId,
      'context': {
        'client': {
          'clientName': 'WEB_REMIX',
          'clientVersion': '1.20240101.00.00',
          'hl': 'en',
          'gl': 'US',
          'userAgent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/120.0.0.0 Safari/537.36,gzip(gfe)',
          'utcOffsetMinutes': 0,
        },
      },
    });

    final response = await http.post(uri, headers: headers, body: body);

    final bodyPreview = response.body.length > 1000
        ? response.body.substring(0, 1000)
        : response.body;

    if (response.statusCode != 200) {
      debugInfo = 'HTTP ${response.statusCode}\n$bodyPreview';
      notifyListeners();
      return null;
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final playabilityStatus = json['playabilityStatus']?['status'];
    final reason = json['playabilityStatus']?['reason'] ?? '';

    if (playabilityStatus != 'OK') {
      debugInfo =
          'playabilityStatus: $playabilityStatus\n'
          'reason: $reason\n\n'
          '$bodyPreview';
      notifyListeners();
      return null;
    }

    final adaptiveFormats =
        (json['streamingData']?['adaptiveFormats'] as List? ?? []);
    final regularFormats = (json['streamingData']?['formats'] as List? ?? []);
    final allFormats = [...adaptiveFormats, ...regularFormats];

    final audioFormats = allFormats
        .where(
          (f) =>
              (f['mimeType'] as String?)?.startsWith('audio/') == true &&
              f['url'] != null,
        )
        .toList();

    if (audioFormats.isEmpty) {
      final mimeTypes = allFormats.map((f) => f['mimeType']).toList();
      final hasUrl = allFormats.map((f) => f['url'] != null).toList();
      debugInfo =
          'No audio+url formats\n'
          'adaptive: ${adaptiveFormats.length}, regular: ${regularFormats.length}\n'
          'mimeTypes: $mimeTypes\n'
          'hasUrl: $hasUrl';
      notifyListeners();
      return null;
    }

    audioFormats.sort(
      (a, b) => ((b['averageBitrate'] ?? b['bitrate'] ?? 0) as int).compareTo(
        (a['averageBitrate'] ?? a['bitrate'] ?? 0) as int,
      ),
    );

    debugInfo = 'OK - found ${audioFormats.length} audio formats';
    return audioFormats.first['url'] as String;
  }

  Future<String?> _resolveVideoIdFromPlaylist(String playlistId) async {
    final auth = _getAuth();
    if (auth == null) return null;

    final response = await http.post(
      Uri.parse('https://music.youtube.com/youtubei/v1/next'),
      headers: {
        'Content-Type': 'application/json',
        'Cookie': auth.buildCookieHeader(),
        'Authorization': auth.buildSapisidHash(),
        'X-Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/120.0.0.0 Safari/537.36',
        'X-Youtube-Client-Name': '67',
        'X-Youtube-Client-Version': '1.20240101.00.00',
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
