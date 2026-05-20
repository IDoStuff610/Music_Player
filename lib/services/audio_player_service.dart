import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:music_player/services/ytmusic_api_service.dart';
import 'package:music_player/user_session.dart';
import 'package:music_player/services/ytmusic_auth_service.dart';
import 'package:http/http.dart' as http;

class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();

  MusicItem? currentItem;
  bool isLoading = false;
  String? error;

  AudioPlayer get player => _player;
  bool get isPlaying => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;

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

    // ✅ Fresh instance per play — avoids stale stream tokens
    // ✅ Inject auth cookies so YouTube recognizes the same session
    final yt = _buildAuthenticatedYT();

    try {
      String? videoIdToPlay = item.videoId;

      if (videoIdToPlay == null && item.playlistId != null) {
        final video = await yt.playlists.getVideos(item.playlistId!).first;
        videoIdToPlay = video.id.value;
      }

      if (videoIdToPlay == null) {
        error = 'Could not find a track to play';
        isLoading = false;
        notifyListeners();
        return;
      }

      final manifest = await yt.videos.streamsClient.getManifest(videoIdToPlay);
      final audioStream = manifest.audioOnly.withHighestBitrate();

      // ✅ AudioSource.uri — LockCachingAudioSource breaks on iOS with expiring URLs
      await _player.setAudioSource(
        AudioSource.uri(
          audioStream.url,
          tag: MediaItem(
            id: videoIdToPlay,
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
      notifyListeners();
    } finally {
      isLoading = false;
      yt.close(); // ✅ Always close the per-request instance
      notifyListeners();
    }
  }

  /// Creates a YoutubeExplode instance with the user's auth cookies injected.
  /// This ensures the stream fetch is seen as the same authenticated session
  /// that fetched the video IDs from YT Music.
  YoutubeExplode _buildAuthenticatedYT() {
    final cookieString = UserSession().ytMusicCookies;

    if (cookieString == null) {
      debugPrint('⚠️ No cookies — fetching stream unauthenticated');
      return YoutubeExplode();
    }

    final auth = YTMusicAuthService.fromCookieString(cookieString);

    return YoutubeExplode(
      YoutubeHttpClient(
        _AuthenticatedHttpClient({
          'Cookie': auth.buildCookieHeader(),
          'Authorization': auth.buildSapisidHash(),
          'X-Origin': 'https://music.youtube.com',
          'Referer': 'https://music.youtube.com/',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
              'AppleWebKit/605.1.15',
        }),
      ),
    );
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

class _AuthenticatedHttpClient extends http.BaseClient {
  final Map<String, String> _extraHeaders;
  final http.Client _inner = http.Client();

  _AuthenticatedHttpClient(this._extraHeaders);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    // Inject auth headers into every request made by YoutubeExplode
    _extraHeaders.forEach((key, value) {
      request.headers[key] = value;
    });
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
