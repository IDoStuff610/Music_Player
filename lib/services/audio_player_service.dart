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

  // Cached API key fetched dynamically from YouTube
  String? _cachedApiKey;

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

  /// Fetches the real INNERTUBE_API_KEY from YouTube's homepage HTML.
  /// This avoids hardcoding keys that expire or change.
  Future<String> _getApiKey() async {
    if (_cachedApiKey != null) return _cachedApiKey!;

    try {
      final response = await http.get(
        Uri.parse('https://www.youtube.com/'),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/120.0.0.0 Safari/537.36',
          'Accept-Language': 'en-US,en;q=0.9',
        },
      );

      final body = response.body;
      final match = RegExp(r'"INNERTUBE_API_KEY":"([^"]+)"').firstMatch(body);
      if (match != null) {
        _cachedApiKey = match.group(1);
        debugPrint('✅ Fetched API key: $_cachedApiKey');
        return _cachedApiKey!;
      }
    } catch (e) {
      debugPrint('Failed to fetch API key: $e');
    }

    // Fallback to known key
    return 'AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8';
  }

  Future<String?> _fetchStreamUrl(String videoId) async {
    final auth = _getAuth();
    if (auth == null) {
      debugInfo = 'auth is null — no cookies found';
      notifyListeners();
      return null;
    }

    final apiKey = await _getApiKey();
    final logs = <String>['apiKey=${apiKey.substring(0, 12)}...'];

    final baseUrl = 'https://www.youtube.com/youtubei/v1/player?key=$apiKey';

    final clients = <Map<String, dynamic>>[
      // ANDROID — current working versions per Invidious/NewPipe
      {
        'name': 'ANDROID',
        'headers': {
          'Content-Type': 'application/json',
          'User-Agent':
              'com.google.android.youtube/19.09.36 (Linux; U; Android 12; US) gzip',
          'X-Goog-Api-Format-Version': '1',
        },
        'body': jsonEncode({
          'videoId': videoId,
          'params': 'CgIQBg==',
          'context': {
            'client': {
              'clientName': 'ANDROID',
              'clientVersion': '19.09.36',
              'androidSdkVersion': 31,
              'osName': 'Android',
              'osVersion': '12',
              'hl': 'en',
              'gl': 'US',
              'utcOffsetMinutes': 0,
            },
          },
        }),
      },
      // IOS — current working versions
      {
        'name': 'IOS',
        'headers': {
          'Content-Type': 'application/json',
          'User-Agent':
              'com.google.ios.youtube/19.09.3 (iPhone16,2; U; CPU iOS 17_4 like Mac OS X)',
          'X-Goog-Api-Format-Version': '1',
        },
        'body': jsonEncode({
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
        }),
      },
      // WEB — authenticated, may return cipher but worth trying
      {
        'name': 'WEB',
        'headers': {
          'Content-Type': 'application/json',
          'Cookie': auth.buildCookieHeader(),
          'Authorization': auth.buildSapisidHash(),
          'X-Origin': 'https://www.youtube.com',
          'Referer': 'https://www.youtube.com/',
          'Origin': 'https://www.youtube.com',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 (KHTML, like Gecko) '
              'Chrome/120.0.0.0 Safari/537.36',
        },
        'body': jsonEncode({
          'videoId': videoId,
          'racyCheckOk': true,
          'contentCheckOk': true,
          'context': {
            'client': {
              'clientName': 'WEB',
              'clientVersion': '2.20240304.00.00',
              'hl': 'en',
              'gl': 'US',
              'utcOffsetMinutes': 0,
            },
          },
        }),
      },
    ];

    for (final client in clients) {
      final name = client['name'] as String;
      try {
        final response = await http.post(
          Uri.parse(baseUrl),
          headers: Map<String, String>.from(client['headers'] as Map),
          body: client['body'] as String,
        );

        if (response.statusCode != 200) {
          logs.add('[$name] HTTP ${response.statusCode}');
          continue;
        }

        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final status = json['playabilityStatus']?['status'];
        final reason = json['playabilityStatus']?['reason'] ?? '';

        if (status != 'OK') {
          logs.add('[$name] status=$status reason=$reason');
          continue;
        }

        final adaptiveFormats =
            (json['streamingData']?['adaptiveFormats'] as List? ?? []);
        final regularFormats =
            (json['streamingData']?['formats'] as List? ?? []);
        final allFormats = [...adaptiveFormats, ...regularFormats];

        final audioWithUrl = allFormats
            .where(
              (f) =>
                  (f['mimeType'] as String?)?.startsWith('audio/') == true &&
                  f['url'] != null,
            )
            .toList();

        final cipherCount = allFormats
            .where((f) => f['signatureCipher'] != null || f['cipher'] != null)
            .length;

        logs.add(
          '[$name] OK total=${allFormats.length} '
          'audioUrl=${audioWithUrl.length} cipher=$cipherCount',
        );

        if (audioWithUrl.isNotEmpty) {
          audioWithUrl.sort(
            (a, b) => ((b['averageBitrate'] ?? b['bitrate'] ?? 0) as int)
                .compareTo((a['averageBitrate'] ?? a['bitrate'] ?? 0) as int),
          );
          debugInfo = '✅ $name worked!\n${logs.join('\n')}';
          notifyListeners();
          return audioWithUrl.first['url'] as String;
        }
      } catch (e) {
        logs.add('[$name] exception: $e');
      }
    }

    debugInfo = 'All clients failed:\n${logs.join('\n')}';
    notifyListeners();
    return null;
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
