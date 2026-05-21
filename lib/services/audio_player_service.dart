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
      debugInfo = (debugInfo ?? '') + '\nException: $e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  // ─── Stream URL extraction ───────────────────────────────────────────────

  Future<String?> _getStreamUrl(String videoId) async {
    final cookies = UserSession().ytMusicCookies;
    final ytmAuth = _getAuth();
    final log = StringBuffer();

    // ── 1. WEB_REMIX (authenticated, music.youtube.com) ──────────────────
    // The actual YT Music web client. With valid cookies this returns
    // plain signed URLs — no cipher needed.
    if (ytmAuth != null) {
      const clientName = 'WEB_REMIX';
      log.writeln('[$clientName]');
      try {
        final resp = await http.post(
          Uri.parse(
            'https://music.youtube.com/youtubei/v1/player?prettyPrint=false',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Cookie': ytmAuth.buildCookieHeader(),
            'Authorization': ytmAuth.buildSapisidHash(),
            'X-Origin': 'https://music.youtube.com',
            'Origin': 'https://music.youtube.com',
            'Referer': 'https://music.youtube.com/',
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 (KHTML, like Gecko) '
                'Chrome/124.0.0.0 Safari/537.36',
          },
          body: jsonEncode({
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            'context': {
              'client': {
                'clientName': clientName,
                'clientVersion': '1.20240508.01.00',
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        );
        log.writeln('HTTP ${resp.statusCode}');
        if (resp.statusCode == 200) {
          final result = _extractAudioUrlVerbose(resp.body);
          log.writeln(result.log);
          if (result.url != null) {
            debugInfo = log.toString();
            notifyListeners();
            return result.url;
          }
        } else {
          log.writeln(resp.body.substring(0, resp.body.length.clamp(0, 300)));
        }
      } catch (e) {
        log.writeln('Exception: $e');
      }
    }

    // ── 2. MWEB (mobile Safari UA, no poToken needed) ────────────────────
    // The mobile web client reliably returns plain URLs on iOS user-agents.
    // Sending cookies makes it work for music that needs login.
    {
      const clientName = 'MWEB';
      log.writeln('\n[$clientName]');
      try {
        final headers = <String, String>{
          'Content-Type': 'application/json',
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) '
              'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 '
              'Mobile/15E148 Safari/604.1',
          'Origin': 'https://www.youtube.com',
          'Referer': 'https://www.youtube.com/',
        };
        if (ytmAuth != null && cookies != null) {
          headers['Cookie'] = ytmAuth.buildCookieHeader();
          headers['Authorization'] = _buildSapisidHash(
            cookies,
            'https://www.youtube.com',
          );
        }
        final resp = await http.post(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
          ),
          headers: headers,
          body: jsonEncode({
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            'context': {
              'client': {
                'clientName': clientName,
                'clientVersion': '2.20240508.01.00',
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        );
        log.writeln('HTTP ${resp.statusCode}');
        if (resp.statusCode == 200) {
          final result = _extractAudioUrlVerbose(resp.body);
          log.writeln(result.log);
          if (result.url != null) {
            debugInfo = log.toString();
            notifyListeners();
            return result.url;
          }
        } else {
          log.writeln(resp.body.substring(0, resp.body.length.clamp(0, 300)));
        }
      } catch (e) {
        log.writeln('Exception: $e');
      }
    }

    // ── 3. IOS_MUSIC client ───────────────────────────────────────────────
    // The actual YouTube Music iOS app client. Always returns plain URLs.
    // Uses the YouTube Music iOS app bundle ID and a current version string.
    {
      const clientName = 'IOS_MUSIC';
      log.writeln('\n[$clientName]');
      try {
        final headers = <String, String>{
          'Content-Type': 'application/json',
          'User-Agent':
              'com.google.ios.youtubemusic/7.16.0 '
              '(iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X; en_US)',
          'X-Youtube-Client-Name': '26',
          'X-Youtube-Client-Version': '7.16.0',
          'Origin': 'https://music.youtube.com',
        };
        if (ytmAuth != null && cookies != null) {
          headers['Cookie'] = ytmAuth.buildCookieHeader();
          headers['Authorization'] = _buildSapisidHash(
            cookies,
            'https://music.youtube.com',
          );
        }
        final resp = await http.post(
          Uri.parse(
            'https://music.youtube.com/youtubei/v1/player?prettyPrint=false',
          ),
          headers: headers,
          body: jsonEncode({
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            'context': {
              'client': {
                'clientName': clientName,
                'clientVersion': '7.16.0',
                'deviceMake': 'Apple',
                'deviceModel': 'iPhone16,2',
                'osName': 'iPhone',
                'osVersion': '17.5.1.21F90',
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        );
        log.writeln('HTTP ${resp.statusCode}');
        if (resp.statusCode == 200) {
          final result = _extractAudioUrlVerbose(resp.body);
          log.writeln(result.log);
          if (result.url != null) {
            debugInfo = log.toString();
            notifyListeners();
            return result.url;
          }
        } else {
          log.writeln(resp.body.substring(0, resp.body.length.clamp(0, 300)));
        }
      } catch (e) {
        log.writeln('Exception: $e');
      }
    }

    // ── 4. IOS client (youtube.com, not music) ────────────────────────────
    // The standard YouTube iOS app — different from Music app.
    // Client name 5, no API key required.
    {
      const clientName = 'IOS';
      log.writeln('\n[$clientName]');
      try {
        final headers = <String, String>{
          'Content-Type': 'application/json',
          'User-Agent':
              'com.google.ios.youtube/19.45.4 '
              '(iPhone16,2; U; CPU iOS 17_5_1 like Mac OS X; en_US)',
          'X-Youtube-Client-Name': '5',
          'X-Youtube-Client-Version': '19.45.4',
          'Origin': 'https://www.youtube.com',
        };
        if (ytmAuth != null && cookies != null) {
          headers['Cookie'] = ytmAuth.buildCookieHeader();
          headers['Authorization'] = _buildSapisidHash(
            cookies,
            'https://www.youtube.com',
          );
        }
        final resp = await http.post(
          Uri.parse(
            'https://www.youtube.com/youtubei/v1/player?prettyPrint=false',
          ),
          headers: headers,
          body: jsonEncode({
            'videoId': videoId,
            'contentCheckOk': true,
            'racyCheckOk': true,
            'context': {
              'client': {
                'clientName': clientName,
                'clientVersion': '19.45.4',
                'deviceMake': 'Apple',
                'deviceModel': 'iPhone16,2',
                'osName': 'iPhone',
                'osVersion': '17.5.1.21F90',
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        );
        log.writeln('HTTP ${resp.statusCode}');
        if (resp.statusCode == 200) {
          final result = _extractAudioUrlVerbose(resp.body);
          log.writeln(result.log);
          if (result.url != null) {
            debugInfo = log.toString();
            notifyListeners();
            return result.url;
          }
        } else {
          log.writeln(resp.body.substring(0, resp.body.length.clamp(0, 300)));
        }
      } catch (e) {
        log.writeln('Exception: $e');
      }
    }

    debugInfo = 'All clients failed:\n${log.toString()}';
    notifyListeners();
    return null;
  }

  // ─── Verbose URL extractor ───────────────────────────────────────────────

  _ExtractResult _extractAudioUrlVerbose(String body) {
    final log = StringBuffer();
    try {
      final j = jsonDecode(body) as Map<String, dynamic>;

      final status = j['playabilityStatus']?['status'] as String?;
      final reason = j['playabilityStatus']?['reason'] as String?;
      log.writeln('  status=$status${reason != null ? ' reason=$reason' : ''}');

      if (status != null && status != 'OK') {
        return _ExtractResult(null, log.toString());
      }

      final adaptive = j['streamingData']?['adaptiveFormats'] as List? ?? [];
      final regular = j['streamingData']?['formats'] as List? ?? [];
      final all = [...adaptive, ...regular];

      int plainCount = 0, cipherCount = 0, audioPlainCount = 0;
      final audioFormats = <Map<String, dynamic>>[];

      for (final f in all) {
        final fmt = f as Map<String, dynamic>;
        final mime = fmt['mimeType']?.toString() ?? '';
        final hasUrl = fmt.containsKey('url');
        final hasCipher =
            fmt.containsKey('signatureCipher') || fmt.containsKey('cipher');
        if (hasUrl) plainCount++;
        if (hasCipher) cipherCount++;
        if (hasUrl && mime.contains('audio')) {
          audioPlainCount++;
          audioFormats.add(fmt);
        }
      }

      log.writeln(
        '  formats=${all.length} plain=$plainCount '
        'ciphered=$cipherCount audioPlain=$audioPlainCount',
      );

      if (audioFormats.isEmpty) {
        // Fall back to any plain format (mixed audio+video)
        if (plainCount > 0) {
          for (final f in all) {
            final fmt = f as Map<String, dynamic>;
            final url = fmt['url'] as String?;
            if (url != null) {
              log.writeln('  ✅ fallback mixed: ${fmt['mimeType']}');
              return _ExtractResult(url, log.toString());
            }
          }
        }
        return _ExtractResult(null, log.toString());
      }

      audioFormats.sort((a, b) {
        final aBr = (a['bitrate'] as num?)?.toInt() ?? 0;
        final bBr = (b['bitrate'] as num?)?.toInt() ?? 0;
        return bBr.compareTo(aBr);
      });

      final m4a = audioFormats.where((f) {
        final mime = f['mimeType']?.toString() ?? '';
        return mime.contains('mp4a.40.2') || mime.contains('audio/mp4');
      }).toList();

      final chosen = m4a.isNotEmpty ? m4a.first : audioFormats.first;
      final url = chosen['url'] as String?;
      if (url == null) return _ExtractResult(null, log.toString());

      log.writeln('  ✅ ${chosen['bitrate']} bps | ${chosen['mimeType']}');
      return _ExtractResult(url, log.toString());
    } catch (e) {
      log.writeln('  parse error: $e');
      return _ExtractResult(null, log.toString());
    }
  }

  // ─── SAPISID hash ────────────────────────────────────────────────────────

  String _buildSapisidHash(String cookieString, String origin) {
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
    final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final hash = sha1.convert(utf8.encode('$ts $sapisid $origin')).toString();
    return 'SAPISIDHASH ${ts}_$hash';
  }

  // ─── Download to temp ────────────────────────────────────────────────────

  Future<File?> _downloadStreamToTemp(String videoId, String streamUrl) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/yt_audio_$videoId.mp4');

      if (await file.exists()) {
        debugInfo = '✅ Using cached file\n${debugInfo ?? ''}';
        notifyListeners();
        return file;
      }

      debugInfo = 'Downloading...\n${debugInfo ?? ''}';
      notifyListeners();

      final req = http.Request('GET', Uri.parse(streamUrl));
      final streamed = await req.send();

      if (streamed.statusCode != 200) {
        debugInfo = 'Download HTTP ${streamed.statusCode}\n${debugInfo ?? ''}';
        notifyListeners();
        return null;
      }

      final out = file.openWrite();
      await streamed.stream.pipe(out);
      await out.flush();
      await out.close();

      final kb = (await file.length()) / 1024;
      debugInfo = '✅ ${kb.toStringAsFixed(1)} KB\n${debugInfo ?? ''}';
      notifyListeners();
      return file;
    } catch (e) {
      debugInfo = 'Download error: $e\n${debugInfo ?? ''}';
      notifyListeners();
      return null;
    }
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  Future<String?> _resolveVideoIdFromPlaylist(String playlistId) async {
    final auth = _getAuth();
    if (auth == null) return null;
    try {
      final resp = await http.post(
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
      if (resp.statusCode != 200) return null;
      final j = jsonDecode(resp.body);
      return j['currentVideoEndpoint']?['watchEndpoint']?['videoId'];
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
      for (final f in files) await f.delete();
    } catch (_) {}
  }

  Future<void> togglePlayPause() async {
    _player.playing ? await _player.pause() : await _player.play();
    notifyListeners();
  }

  Future<void> seekTo(Duration position) async => _player.seek(position);

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }
}

// ─── Internal result type ─────────────────────────────────────────────────────

class _ExtractResult {
  final String? url;
  final String log;
  const _ExtractResult(this.url, this.log);
}
