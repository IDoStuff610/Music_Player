import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:music_player/services/ytmusic_api_service.dart';

class AudioPlayerService extends ChangeNotifier {
  static final AudioPlayerService _instance = AudioPlayerService._internal();
  factory AudioPlayerService() => _instance;
  AudioPlayerService._internal();

  final AudioPlayer _player = AudioPlayer();
  final YoutubeExplode _yt = YoutubeExplode();

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

    try {
      String? videoIdToPlay = item.videoId;

      if (videoIdToPlay == null && item.playlistId != null) {
        final playlist = await _yt.playlists.getVideos(item.playlistId!).first;
        videoIdToPlay = playlist.id.value;
      }

      if (videoIdToPlay == null) {
        error = 'Could not find a track to play';
        isLoading = false;
        notifyListeners();
        return;
      }

      final manifest = await _yt.videos.streamsClient.getManifest(
        videoIdToPlay,
      );
      final audioStream = manifest.audioOnly.withHighestBitrate();
      final streamUrl = audioStream.url.toString();

      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(streamUrl),
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
      error = e.toString(); // keep currentItem so player stays open
      isLoading = false;
      notifyListeners();
    } finally {
      isLoading = false;
      notifyListeners();
    }
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

  void dispose() {
    _player.dispose();
    _yt.close();
    super.dispose();
  }
}
