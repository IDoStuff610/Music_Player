import 'dart:convert';
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
      final mimeType = result['mimeType'];

      debugPrint('▶️ Playing: $streamUrl');
      debugPrint('▶️ mimeType: $mimeType');

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
      debugInfo = (debugInfo ?? '') + '\nPlayer error: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<Map<String, String>?> _fetchStreamUrl(String videoId) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);

      // Log ALL audio streams so we can see what's available
      final allAudio = manifest.audioOnly.sortByBitrate();
      final logLines = <String>['All audio streams:'];
      for (final s in allAudio) {
        logLines.add('  ${s.bitrate} | ${s.codec} | ${s.container}');
      }
      debugPrint(logLines.join('\n'));

      if (allAudio.isEmpty) {
        debugInfo = 'No audio streams found';
        notifyListeners();
        return null;
      }

      // Prefer mp4/aac streams — iOS handles these natively
      // mp4a.40.2 = AAC-LC (best), mp4a.40.5 = HE-AAC (low bitrate fallback)
      final mp4Streams = allAudio
          .where(
            (s) =>
                s.codec.mimeType.contains('mp4') &&
                s.codec.toString().contains('mp4a.40.2'),
          ) // AAC-LC only
          .toList();

      // Fall back to any mp4 stream
      final anyMp4 = allAudio
          .where((s) => s.codec.mimeType.contains('mp4'))
          .toList();

      // Fall back to any stream at all
      final chosen = mp4Streams.isNotEmpty
          ? mp4Streams
                .last // highest bitrate AAC-LC
          : anyMp4.isNotEmpty
          ? anyMp4
                .last // highest bitrate mp4
          : allAudio.last; // anything

      final url = chosen.url.toString();
      debugInfo =
          '✅ Stream chosen:\n'
          'bitrate: ${chosen.bitrate}\n'
          'codec: ${chosen.codec}\n'
          'container: ${chosen.container}\n'
          'all streams: ${allAudio.length}';
      notifyListeners();

      return {'url': url, 'mimeType': chosen.codec.mimeType};
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
