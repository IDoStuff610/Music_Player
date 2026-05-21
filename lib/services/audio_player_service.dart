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

  /// Calls YouTube's internal InnerTube /player endpoint using the user's
  /// authenticated cookies. This is exactly what OuterTune/InnerTune do on
  /// Android — impersonate the iOS YouTube client so we get direct,
  /// non-throttled, signed audio URLs.
  ///
  /// Why this works when youtube_explode_dart doesn't:
  ///   - youtube_explode scrapes youtube.com/watch as an anonymous client
  ///     → YouTube rate-limits it after a few requests
  ///   - This call uses the user's SAPISID cookies so YouTube treats it as
  ///     an authenticated first-party iOS client → no rate limiting
  Future<String?> _getStreamUrlFromInnertube(String videoId) async {
    final auth = _getAuth();
    if (auth == null) {
      debugInfo = 'No auth cookies available';
      notifyListeners();
      return null;
    }

    try {
      debugInfo = 'Calling InnerTube player API...';
      notifyListeners();

      // Impersonate the official iOS YouTube app.
      // The IOS client returns plain HTTPS MP4 URLs that AVPlayer can play
      // natively on iPhone — no deciphering needed.
      final response = await http.post(
        Uri.parse(
          'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
        ),
        headers: {
          'Content-Type': 'application/json',
          'Cookie': auth.buildCookieHeader(),
          'Authorization': auth.buildSapisidHash(),
          'X-Origin': 'https://www.youtube.com',
          'Origin': 'https://www.youtube.com',
          'Referer': 'https://www.youtube.com/',
          // Must match the iOS client below or YouTube may reject the request
          'User-Agent':
              'com.google.ios.youtube/19.29.1 (iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X)',
        },
        body: jsonEncode({
          'videoId': videoId,
          'contentCheckOk': true,
          'racyCheckOk': true,
          'context': {
            'client': {
              'clientName': 'IOS',
              'clientVersion': '19.29.1',
              'deviceMake': 'Apple',
              'deviceModel': 'iPhone16,2', // iPhone 15 Pro Max
              'osName': 'iPhone',
              'osVersion': '17.5.1.22F82',
              'hl': 'en',
              'gl': 'US',
            },
          },
        }),
      );

      if (response.statusCode != 200) {
        debugInfo = 'InnerTube player returned ${response.statusCode}';
        notifyListeners();
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;

      // Check playability status first
      final status = json['playabilityStatus']?['status'] as String?;
      if (status != null && status != 'OK') {
        final reason = json['playabilityStatus']?['reason'] ?? 'Unknown';
        debugInfo = 'Not playable: $status — $reason';
        notifyListeners();
        return null;
      }

      final adaptiveFormats =
          json['streamingData']?['adaptiveFormats'] as List?;
      final formats = json['streamingData']?['formats'] as List?;

      // Prefer adaptive audio-only streams (better quality, audio-only)
      final allAudio = <Map<String, dynamic>>[];

      if (adaptiveFormats != null) {
        for (final f in adaptiveFormats) {
          final mime = f['mimeType']?.toString() ?? '';
          if (mime.contains('audio')) {
            allAudio.add(f as Map<String, dynamic>);
          }
        }
      }

      // Fall back to combined formats if no audio-only found
      if (allAudio.isEmpty && formats != null) {
        for (final f in formats) {
          allAudio.add(f as Map<String, dynamic>);
        }
      }

      if (allAudio.isEmpty) {
        debugInfo = 'No audio formats in InnerTube response';
        notifyListeners();
        return null;
      }

      // Sort by bitrate, pick highest
      allAudio.sort((a, b) {
        final aBitrate = (a['bitrate'] as num?)?.toInt() ?? 0;
        final bBitrate = (b['bitrate'] as num?)?.toInt() ?? 0;
        return bBitrate.compareTo(aBitrate);
      });

      // Prefer m4a (mp4a.40.2 = AAC-LC) — natively supported on iOS
      final m4aFormats = allAudio.where((f) {
        final mime = f['mimeType']?.toString() ?? '';
        return mime.contains('mp4a.40.2') || mime.contains('audio/mp4');
      }).toList();

      final chosen = m4aFormats.isNotEmpty ? m4aFormats.first : allAudio.first;
      final url = chosen['url'] as String?;

      final bitrate = chosen['bitrate'];
      final mime = chosen['mimeType'];
      debugInfo = '✅ InnerTube stream: $bitrate bps | $mime';
      notifyListeners();

      return url;
    } catch (e) {
      debugInfo = 'InnerTube error: $e';
      notifyListeners();
      return null;
    }
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
