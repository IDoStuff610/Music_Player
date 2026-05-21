import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:music_player/services/ytmusic_api_service.dart';
import 'package:music_player/services/ytmusic_auth_service.dart';
import 'package:music_player/user_session.dart';
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

      final streamUrl = await _getStreamUrl(videoId);

      if (streamUrl == null) {
        error = 'Could not get stream URL\n\n$debugInfo';
        isLoading = false;
        notifyListeners();
        return;
      }

      final tempFile = await _downloadStreamToTemp(videoId, streamUrl);

      if (tempFile == null) {
        error = 'Download failed\n\n$debugInfo';
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

  // ─── Stream URL extraction ───────────────────────────────────────────────

  Future<String?> _getStreamUrl(String videoId) async {
    final cookies = UserSession().ytMusicCookies;

    // Build SAPISID hash for www.youtube.com (needed for IOS/TV clients)
    final wwwAuth = cookies != null
        ? _buildSapisidHash(cookies, 'https://www.youtube.com')
        : null;
    // Build SAPISID hash for music.youtube.com (for WEB_REMIX)
    final ytmAuth = _getAuth();

    // ── Client attempt list ──────────────────────────────────────────────
    //
    // IMPORTANT: WEB_REMIX and most web clients return *ciphered* URLs
    // (signatureCipher field, no plain `url`). We need clients that return
    // plain signed HTTPS URLs. Those are:
    //   • TVHTML5_SIMPLY_EMBEDDED_PLAYER  – no auth needed, always plain URLs
    //   • IOS                             – plain URLs, needs correct API key
    //   • ANDROID_MUSIC                   – plain URLs, needs correct API key
    //
    // We try them in order and log every step so you can see exactly
    // what each one returns.

    String log = '';

    // ── 1. TVHTML5_SIMPLY_EMBEDDED_PLAYER (no auth required) ─────────────
    // This is the Smart TV embedded player. It needs no cookies at all and
    // always returns plain URLs. Works for most videos.
    {
      const clientName = 'TVHTML5_SIMPLY_EMBEDDED_PLAYER';
      log += '\n[$clientName]\n';
      try {
        final resp = await http.post(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/player'
            '?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8'
            '&prettyPrint=false',
          ),
          headers: {
            'Content-Type': 'application/json',
            'User-Agent':
                'Mozilla/5.0 (SMART-TV; Linux; Tizen 6.0) AppleWebKit/538.1 '
                '(KHTML, like Gecko) Version/6.0 TV Safari/538.1',
            'X-Youtube-Client-Name': '85',
            'X-Youtube-Client-Version': '2.0',
          },
          body: jsonEncode({
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            'context': {
              'client': {
                'clientName': clientName,
                'clientVersion': '2.0',
                'hl': 'en',
                'gl': 'US',
              },
              'thirdParty': {'embedUrl': 'https://www.youtube.com'},
            },
          }),
        );
        log += 'HTTP ${resp.statusCode}\n';
        if (resp.statusCode == 200) {
          final url = _extractAudioUrl(resp.body, clientName, log);
          if (url != null) {
            debugInfo = log;
            notifyListeners();
            return url;
          }
          // Show what fields streamingData actually has
          try {
            final j = jsonDecode(resp.body) as Map<String, dynamic>;
            final status = j['playabilityStatus']?['status'];
            final reason = j['playabilityStatus']?['reason'];
            final hasStreaming = j.containsKey('streamingData');
            final adaptiveCount =
                (j['streamingData']?['adaptiveFormats'] as List?)?.length ?? 0;
            final hasCipher =
                (j['streamingData']?['adaptiveFormats'] as List?)?.any(
                  (f) => f['signatureCipher'] != null || f['cipher'] != null,
                ) ??
                false;
            log +=
                'status=$status reason=$reason hasStreaming=$hasStreaming '
                'adaptiveCount=$adaptiveCount hasCipher=$hasCipher\n';
          } catch (_) {}
        } else {
          log += resp.body.substring(0, resp.body.length.clamp(0, 200)) + '\n';
        }
      } catch (e) {
        log += 'Exception: $e\n';
      }
    }

    // ── 2. IOS client (authenticated) ─────────────────────────────────────
    if (wwwAuth != null && cookies != null) {
      const clientName = 'IOS';
      log += '\n[$clientName]\n';
      try {
        final cookieStr = YTMusicAuthService.fromCookieString(
          cookies,
        ).buildCookieHeader();
        final resp = await http.post(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/player'
            '?key=AIzaSyB-63vPrdThhKuerbB2N_l7Kwwcxj6yUAc'
            '&prettyPrint=false',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Cookie': cookieStr,
            'Authorization': wwwAuth,
            'X-Origin': 'https://www.youtube.com',
            'Origin': 'https://www.youtube.com',
            'Referer': 'https://www.youtube.com/',
            'User-Agent':
                'com.google.ios.youtube/19.29.1 (iPhone16,2; U; '
                'CPU iOS 17_5_1 like Mac OS X)',
            'X-Youtube-Client-Name': '5',
            'X-Youtube-Client-Version': '19.29.1',
          },
          body: jsonEncode({
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            'context': {
              'client': {
                'clientName': clientName,
                'clientVersion': '19.29.1',
                'deviceMake': 'Apple',
                'deviceModel': 'iPhone16,2',
                'osName': 'iPhone',
                'osVersion': '17.5.1.22F82',
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        );
        log += 'HTTP ${resp.statusCode}\n';
        if (resp.statusCode == 200) {
          final url = _extractAudioUrl(resp.body, clientName, log);
          if (url != null) {
            debugInfo = log;
            notifyListeners();
            return url;
          }
          try {
            final j = jsonDecode(resp.body) as Map<String, dynamic>;
            final status = j['playabilityStatus']?['status'];
            final reason = j['playabilityStatus']?['reason'];
            final adaptiveCount =
                (j['streamingData']?['adaptiveFormats'] as List?)?.length ?? 0;
            final hasCipher =
                (j['streamingData']?['adaptiveFormats'] as List?)?.any(
                  (f) => f['signatureCipher'] != null || f['cipher'] != null,
                ) ??
                false;
            log +=
                'status=$status reason=$reason adaptiveCount=$adaptiveCount '
                'hasCipher=$hasCipher\n';
          } catch (_) {}
        } else {
          log += resp.body.substring(0, resp.body.length.clamp(0, 200)) + '\n';
        }
      } catch (e) {
        log += 'Exception: $e\n';
      }
    }

    // ── 3. ANDROID_MUSIC (authenticated, music.youtube.com) ───────────────
    if (ytmAuth != null) {
      const clientName = 'ANDROID_MUSIC';
      log += '\n[$clientName]\n';
      try {
        final resp = await http.post(
          Uri.parse(
            'https://music.youtube.com/youtubei/v1/player'
            '?key=AIzaSyC9XL3ZjWddXya6X74dJoCTL-WEYFDNX30'
            '&prettyPrint=false',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Cookie': ytmAuth.buildCookieHeader(),
            'Authorization': ytmAuth.buildSapisidHash(),
            'X-Origin': 'https://music.youtube.com',
            'Origin': 'https://music.youtube.com',
            'Referer': 'https://music.youtube.com/',
            'User-Agent':
                'com.google.android.apps.youtube.music/7.27.52 (Linux; U; '
                'Android 14; Pixel 8 Build/UP1A.231005.007) gzip',
            'X-Youtube-Client-Name': '21',
            'X-Youtube-Client-Version': '7.27.52',
          },
          body: jsonEncode({
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            'context': {
              'client': {
                'clientName': clientName,
                'clientVersion': '7.27.52',
                'androidSdkVersion': 34,
                'osName': 'Android',
                'osVersion': '14',
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        );
        log += 'HTTP ${resp.statusCode}\n';
        if (resp.statusCode == 200) {
          final url = _extractAudioUrl(resp.body, clientName, log);
          if (url != null) {
            debugInfo = log;
            notifyListeners();
            return url;
          }
          try {
            final j = jsonDecode(resp.body) as Map<String, dynamic>;
            final status = j['playabilityStatus']?['status'];
            final reason = j['playabilityStatus']?['reason'];
            final adaptiveCount =
                (j['streamingData']?['adaptiveFormats'] as List?)?.length ?? 0;
            final hasCipher =
                (j['streamingData']?['adaptiveFormats'] as List?)?.any(
                  (f) => f['signatureCipher'] != null || f['cipher'] != null,
                ) ??
                false;
            log +=
                'status=$status reason=$reason adaptiveCount=$adaptiveCount '
                'hasCipher=$hasCipher\n';
          } catch (_) {}
        } else {
          log += resp.body.substring(0, resp.body.length.clamp(0, 200)) + '\n';
        }
      } catch (e) {
        log += 'Exception: $e\n';
      }
    }

    debugInfo = 'All clients failed:\n$log';
    notifyListeners();
    return null;
  }

  /// Parses the player response and returns the best plain audio URL.
  /// Returns null if all URLs are ciphered or formats are missing.
  String? _extractAudioUrl(String body, String clientName, String log) {
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;

      final status = j['playabilityStatus']?['status'] as String?;
      if (status != null && status != 'OK') return null;

      final adaptive = j['streamingData']?['adaptiveFormats'] as List? ?? [];
      final regular = j['streamingData']?['formats'] as List? ?? [];

      final allAudio = <Map<String, dynamic>>[];
      for (final f in [...adaptive, ...regular]) {
        final fmt = f as Map<String, dynamic>;
        final mime = fmt['mimeType']?.toString() ?? '';
        final hasUrl = fmt.containsKey('url');
        // Skip ciphered entries
        if (!hasUrl) continue;
        if (mime.contains('audio') || adaptive.isEmpty) allAudio.add(fmt);
      }

      if (allAudio.isEmpty) return null;

      allAudio.sort((a, b) {
        final aBr = (a['bitrate'] as num?)?.toInt() ?? 0;
        final bBr = (b['bitrate'] as num?)?.toInt() ?? 0;
        return bBr.compareTo(aBr);
      });

      final m4a = allAudio.where((f) {
        final mime = f['mimeType']?.toString() ?? '';
        return mime.contains('mp4a.40.2') || mime.contains('audio/mp4');
      }).toList();

      final chosen = m4a.isNotEmpty ? m4a.first : allAudio.first;
      final url = chosen['url'] as String?;
      if (url == null) return null;

      final bitrate = chosen['bitrate'];
      final mime = chosen['mimeType'];
      debugInfo = '✅ $clientName: $bitrate bps | $mime\n$log';
      notifyListeners();
      return url;
    } catch (_) {
      return null;
    }
  }

  /// Builds a SAPISID hash for an arbitrary origin.
  /// The built-in YTMusicAuthService always hashes for music.youtube.com,
  /// but IOS/TV clients go to www.youtube.com and need a different hash.
  String _buildSapisidHash(String cookieString, String origin) {
    // Extract SAPISID or __Secure-3PAPISID from the cookie string
    String? sapisid;
    for (final pair in cookieString.split('; ')) {
      final eq = pair.indexOf('=');
      if (eq == -1) continue;
      final key = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (key == '__Secure-3PAPISID' || (sapisid == null && key == 'SAPISID')) {
        sapisid = value;
      }
    }
    if (sapisid == null) return '';
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final input = '$timestamp $sapisid $origin';
    final hash = sha1.convert(utf8.encode(input)).toString();
    return 'SAPISIDHASH ${timestamp}_$hash';
  }

  // ─── Download to temp ───────────────────────────────────────────────────

  Future<File?> _downloadStreamToTemp(String videoId, String streamUrl) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/yt_audio_$videoId.mp4');

      if (await file.exists()) {
        debugInfo = '✅ Using cached file\n$debugInfo';
        notifyListeners();
        return file;
      }

      debugInfo = 'Downloading...\n$debugInfo';
      notifyListeners();

      final request = http.Request('GET', Uri.parse(streamUrl));
      final streamedResponse = await request.send();

      if (streamedResponse.statusCode != 200) {
        debugInfo = 'Download HTTP ${streamedResponse.statusCode}\n$debugInfo';
        notifyListeners();
        return null;
      }

      final output = file.openWrite();
      await streamedResponse.stream.pipe(output);
      await output.flush();
      await output.close();

      final fileSize = await file.length();
      debugInfo =
          '✅ ${(fileSize / 1024).toStringAsFixed(1)} KB downloaded\n$debugInfo';
      notifyListeners();
      return file;
    } catch (e) {
      debugInfo = 'Download error: $e\n$debugInfo';
      notifyListeners();
      return null;
    }
  }

  // ─── Helpers ────────────────────────────────────────────────────────────

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
