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
import 'package:path_provider/path_provider.dart';

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

      // Download the stream to a temp file using yt_explode's own HTTP client
      // This avoids the 403 that happens when just_audio opens the URL fresh
      final tempFile = await _downloadToTemp(videoId);

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

  /// Downloads the audio stream to a temp file using youtube_explode's
  /// own HTTP client — avoids the 403 that occurs when another client
  /// tries to open the URL independently.
  Future<File?> _downloadToTemp(String videoId) async {
    final yt = YoutubeExplode();
    try {
      debugInfo = 'Fetching stream info...';
      notifyListeners();

      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      final allAudio = manifest.audioOnly.sortByBitrate();

      if (allAudio.isEmpty) {
        debugInfo = 'No audio streams found';
        notifyListeners();
        return null;
      }

      // Pick best AAC-LC stream (most compatible with iOS)
      final aacStreams = allAudio
          .where((s) => s.codec.toString().contains('mp4a.40.2'))
          .toList();
      final chosen = aacStreams.isNotEmpty ? aacStreams.last : allAudio.last;

      debugInfo =
          'Downloading: ${chosen.bitrate} | ${chosen.codec}\n'
          'size: ${chosen.size}';
      notifyListeners();

      // Get a temp directory and write the file there
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/yt_audio_$videoId.mp4');

      // If we already cached this track, use it
      if (await file.exists()) {
        debugInfo = '✅ Using cached file\n$debugInfo';
        notifyListeners();
        return file;
      }

      // Stream the bytes from yt_explode directly into the file
      final audioStream = yt.videos.streamsClient.get(chosen);
      final output = file.openWrite();
      await audioStream.pipe(output);
      await output.flush();
      await output.close();

      final fileSize = await file.length();
      debugInfo =
          '✅ Downloaded ${(fileSize / 1024).toStringAsFixed(1)} KB\n'
          'codec: ${chosen.codec}\n'
          'bitrate: ${chosen.bitrate}';
      notifyListeners();

      return file;
    } catch (e) {
      debugInfo = 'Download error: $e';
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

  /// Call this when you want to clear cached audio files
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
