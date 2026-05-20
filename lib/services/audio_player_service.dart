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

      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(streamUrl),
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

    // Try multiple clients in order until one returns a plain URL
    final clients = [_buildTvEmbeddedBody(videoId), _buildIosBody(videoId)];

    final clientNames = ['TVHTML5_SIMPLY_EMBEDDED_PLAYER', 'IOS'];

    for (int i = 0; i < clients.length; i++) {
      debugPrint('Trying client: ${clientNames[i]}');

      final headers = <String, String>{
        'Content-Type': 'application/json',
        'Cookie': auth.buildCookieHeader(),
        'Authorization': auth.buildSapisidHash(),
        'X-Origin': 'https://music.youtube.com',
        'Referer': 'https://music.youtube.com/',
        'Origin': 'https://music.youtube.com',
      };

      final response = await http.post(
        Uri.parse('https://music.youtube.com/youtubei/v1/player'),
        headers: headers,
        body: clients[i],
      );

      if (response.statusCode != 200) {
        debugInfo = '${clientNames[i]}: HTTP ${response.statusCode}';
        continue;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final playabilityStatus = json['playabilityStatus']?['status'];

      if (playabilityStatus != 'OK') {
        debugInfo =
            '${clientNames[i]}: status=$playabilityStatus\n'
            'reason=${json['playabilityStatus']?['reason']}';
        continue;
      }

      final adaptiveFormats =
          (json['streamingData']?['adaptiveFormats'] as List? ?? []);
      final regularFormats = (json['streamingData']?['formats'] as List? ?? []);
      final allFormats = [...adaptiveFormats, ...regularFormats];

      // Check which formats have plain URLs vs cipher
      final withUrl = allFormats.where((f) => f['url'] != null).toList();
      final withCipher = allFormats
          .where((f) => f['signatureCipher'] != null || f['cipher'] != null)
          .toList();

      debugPrint(
        '${clientNames[i]}: ${allFormats.length} formats, '
        '${withUrl.length} with url, ${withCipher.length} with cipher',
      );

      final audioWithUrl = withUrl
          .where(
            (f) => (f['mimeType'] as String?)?.startsWith('audio/') == true,
          )
          .toList();

      if (audioWithUrl.isNotEmpty) {
        audioWithUrl.sort(
          (a, b) => ((b['averageBitrate'] ?? b['bitrate'] ?? 0) as int)
              .compareTo((a['averageBitrate'] ?? a['bitrate'] ?? 0) as int),
        );
        debugInfo =
            '✅ ${clientNames[i]}: ${audioWithUrl.length} audio formats found';
        notifyListeners();
        return audioWithUrl.first['url'] as String;
      }

      // If we have cipher formats, report it clearly
      if (withCipher.isNotEmpty) {
        debugInfo =
            '${clientNames[i]}: ${withCipher.length} cipher-only formats '
            '(no plain URL) — trying next client...';
      } else {
        debugInfo = '${clientNames[i]}: 0 audio formats at all';
      }
    }

    // All clients failed
    notifyListeners();
    return null;
  }

  // TVHTML5_SIMPLY_EMBEDDED_PLAYER — known to skip cipher on many videos
  String _buildTvEmbeddedBody(String videoId) {
    return jsonEncode({
      'videoId': videoId,
      'context': {
        'client': {
          'clientName': 'TVHTML5_SIMPLY_EMBEDDED_PLAYER',
          'clientVersion': '2.0',
          'hl': 'en',
          'gl': 'US',
          'utcOffsetMinutes': 0,
        },
        'thirdParty': {'embedUrl': 'https://music.youtube.com'},
      },
    });
  }

  // IOS client — also tends to return plain URLs
  String _buildIosBody(String videoId) {
    return jsonEncode({
      'videoId': videoId,
      'context': {
        'client': {
          'clientName': 'IOS',
          'clientVersion': '19.09.3',
          'deviceMake': 'Apple',
          'deviceModel': 'iPhone16,2',
          'osName': 'iPhone',
          'osVersion': '17.4.0.21E219',
          'hl': 'en',
          'gl': 'US',
          'utcOffsetMinutes': 0,
        },
      },
    });
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
