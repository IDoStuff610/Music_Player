import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:music_player/services/ytmusic_api_service.dart';
import 'package:music_player/services/ytmusic_auth_service.dart';
import 'package:music_player/user_session.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

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

      final result = await _fetchStreamUrl(videoId);

      if (result == null) {
        error = 'Could not get stream URL';
        isLoading = false;
        notifyListeners();
        return;
      }

      final streamUrl = result['url']!;

      // Step 1: verify the URL is actually reachable before giving it to just_audio
      try {
        final probe = await http
            .head(
              Uri.parse(streamUrl),
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                    'AppleWebKit/537.36 (KHTML, like Gecko) '
                    'Chrome/120.0.0.0 Safari/537.36',
                'Referer': 'https://www.youtube.com/',
              },
            )
            .timeout(const Duration(seconds: 10));

        debugInfo =
            (debugInfo ?? '') +
            '\nURL probe: HTTP ${probe.statusCode}'
                '\ncontent-type: ${probe.headers['content-type']}'
                '\ncontent-length: ${probe.headers['content-length']}';
        notifyListeners();

        if (probe.statusCode == 403) {
          error = 'Stream URL expired (403) — try again';
          isLoading = false;
          notifyListeners();
          return;
        }
      } catch (e) {
        debugInfo = (debugInfo ?? '') + '\nURL probe failed: $e';
        notifyListeners();
      }

      // Step 2: set audio source — try with headers first
      try {
        await _player.setAudioSource(
          AudioSource.uri(
            Uri.parse(streamUrl),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                  'AppleWebKit/537.36 (KHTML, like Gecko) '
                  'Chrome/120.0.0.0 Safari/537.36',
              'Referer': 'https://www.youtube.com/',
              'Origin': 'https://www.youtube.com',
            },
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
      } on PlayerException catch (e) {
        debugInfo =
            (debugInfo ?? '') +
            '\nsetAudioSource failed: code=${e.code} msg=${e.message}';
        notifyListeners();
        error = 'Player error ${e.code}: ${e.message}';
        isLoading = false;
        notifyListeners();
        return;
      }

      await _player.play();
    } catch (e) {
      error = e.toString();
      debugInfo = (debugInfo ?? '') + '\nOuter catch: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<Map<String, String>?> _fetchStreamUrl(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final allAudio = manifest.audioOnly.sortByBitrate();

      if (allAudio.isEmpty) {
        debugInfo = 'No audio streams found';
        notifyListeners();
        return null;
      }

      // Log all available streams
      final logLines = <String>['Available streams (${allAudio.length}):'];
      for (final s in allAudio) {
        logLines.add('  ${s.bitrate} | ${s.codec}');
      }
      debugPrint(logLines.join('\n'));

      // Prefer AAC-LC (mp4a.40.2) — most compatible with iOS AVPlayer
      final aacLC = allAudio
          .where((s) => s.codec.toString().contains('mp4a.40.2'))
          .toList();

      final chosen = aacLC.isNotEmpty ? aacLC.last : allAudio.last;

      debugInfo = '✅ Stream: ${chosen.bitrate} | ${chosen.codec}';
      notifyListeners();

      return {'url': chosen.url.toString()};
    } catch (e) {
      debugInfo = 'youtube_explode error: $e';
      notifyListeners();
      return null;
    } finally {
      yt.close();
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
