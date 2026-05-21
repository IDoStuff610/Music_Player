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

  // Cache the cipher functions so we don't re-fetch the player JS every time
  List<_CipherOp>? _cachedCipherOps;
  String? _cachedPlayerUrl;

  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration> get positionStream => _player.positionStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  bool get isPlaying => _player.playing;
  Duration get position => _player.position;
  Duration? get duration => _player.duration;

  // ─── Public play ──────────────────────────────────────────────────────────

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

  // ─── Stream URL ───────────────────────────────────────────────────────────

  Future<String?> _getStreamUrl(String videoId) async {
    final cookies = UserSession().ytMusicCookies;
    final ytmAuth = _getAuth();
    final log = StringBuffer();

    // ── Step 1: get player response via WEB_REMIX (authenticated) ──────────
    // We know this returns HTTP 200 with ciphered URLs.
    // We'll decipher them using the YouTube player JS.
    log.writeln('[WEB_REMIX]');
    Map<String, dynamic>? playerJson;
    String? playerUrl;

    if (ytmAuth != null) {
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
                'clientName': 'WEB_REMIX',
                'clientVersion': '1.20240508.01.00',
                'hl': 'en',
                'gl': 'US',
              },
            },
          }),
        );
        log.writeln('HTTP ${resp.statusCode}');
        if (resp.statusCode == 200) {
          playerJson = jsonDecode(resp.body) as Map<String, dynamic>;
          // Extract the player JS URL embedded in the response
          playerUrl = _extractPlayerUrl(resp.body);
          log.writeln('playerUrl: ${playerUrl ?? 'not found in response'}');
        } else {
          log.writeln(resp.body.substring(0, resp.body.length.clamp(0, 300)));
        }
      } catch (e) {
        log.writeln('Exception: $e');
      }
    }

    // ── Step 2: If we have ciphered formats, decipher them ─────────────────
    if (playerJson != null) {
      final status = playerJson['playabilityStatus']?['status'] as String?;
      log.writeln('status=$status');

      if (status == 'OK') {
        final adaptive =
            playerJson['streamingData']?['adaptiveFormats'] as List? ?? [];
        final regular = playerJson['streamingData']?['formats'] as List? ?? [];
        final all = [...adaptive, ...regular];

        int plain = 0, ciphered = 0;
        for (final f in all) {
          final fmt = f as Map<String, dynamic>;
          if (fmt.containsKey('url')) plain++;
          if (fmt.containsKey('signatureCipher') || fmt.containsKey('cipher'))
            ciphered++;
        }
        log.writeln('formats=${all.length} plain=$plain ciphered=$ciphered');

        // Try plain URLs first (sometimes present for certain videos)
        final plainUrl = _pickBestAudioUrl(all, plain: true);
        if (plainUrl != null) {
          log.writeln('✅ Plain URL found, no decipher needed');
          debugInfo = log.toString();
          notifyListeners();
          return plainUrl;
        }

        // Need to decipher — fetch player JS and extract cipher operations
        if (ciphered > 0) {
          log.writeln('\n[DECIPHER] Fetching player JS...');
          final ops = await _getCipherOps(playerUrl, log);

          if (ops != null && ops.isNotEmpty) {
            log.writeln('Got ${ops.length} cipher ops');
            final url = _decipherBestAudio(all, ops, log);
            if (url != null) {
              debugInfo = log.toString();
              notifyListeners();
              return url;
            }
            log.writeln('Decipher produced no valid URL');
          } else {
            log.writeln('Could not extract cipher ops from player JS');
          }
        }
      }
    }

    // ── Step 3: MWEB fallback with decipher ────────────────────────────────
    log.writeln('\n[MWEB]');
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
              'clientName': 'MWEB',
              'clientVersion': '2.20240508.01.00',
              'hl': 'en',
              'gl': 'US',
            },
          },
        }),
      );
      log.writeln('HTTP ${resp.statusCode}');
      if (resp.statusCode == 200) {
        final j = jsonDecode(resp.body) as Map<String, dynamic>;
        final pUrl = playerUrl ?? _extractPlayerUrl(resp.body);
        final status = j['playabilityStatus']?['status'] as String?;
        log.writeln('status=$status');
        if (status == 'OK') {
          final adaptive =
              j['streamingData']?['adaptiveFormats'] as List? ?? [];
          final regular = j['streamingData']?['formats'] as List? ?? [];
          final all = [...adaptive, ...regular];

          final plainUrl = _pickBestAudioUrl(all, plain: true);
          if (plainUrl != null) {
            log.writeln('✅ MWEB plain URL');
            debugInfo = log.toString();
            notifyListeners();
            return plainUrl;
          }

          final ops = await _getCipherOps(pUrl, log);
          if (ops != null) {
            final url = _decipherBestAudio(all, ops, log);
            if (url != null) {
              debugInfo = log.toString();
              notifyListeners();
              return url;
            }
          }
        }
      } else {
        log.writeln(resp.body.substring(0, resp.body.length.clamp(0, 300)));
      }
    } catch (e) {
      log.writeln('Exception: $e');
    }

    debugInfo = 'All clients failed:\n${log.toString()}';
    notifyListeners();
    return null;
  }

  // ─── Cipher: fetch player JS and extract ops ─────────────────────────────

  /// Returns the base player JS URL from the page HTML or API response.
  String? _extractPlayerUrl(String body) {
    // Look for /s/player/<hash>/player_ias.vflset/en_US/base.js
    final re = RegExp(r'/s/player/[a-f0-9]+/player_ias\.vflset/[^"]+base\.js');
    final m = re.firstMatch(body);
    if (m != null) return 'https://www.youtube.com${m.group(0)}';
    // Fallback: look for any base.js reference
    final re2 = RegExp(r'(/yts/jsbin/player[^"]+\.js)');
    final m2 = re2.firstMatch(body);
    if (m2 != null) return 'https://www.youtube.com${m2.group(0)}';
    return null;
  }

  Future<List<_CipherOp>?> _getCipherOps(
    String? playerUrl,
    StringBuffer log,
  ) async {
    // If we already parsed ops for this player version, reuse them
    if (_cachedCipherOps != null && _cachedPlayerUrl == playerUrl) {
      log.writeln('Using cached cipher ops');
      return _cachedCipherOps;
    }

    // If no playerUrl from the API response, fetch the watch page to find it
    String? jsUrl = playerUrl;
    if (jsUrl == null) {
      log.writeln('Fetching watch page to find player JS...');
      try {
        final watchResp = await http.get(
          Uri.parse('https://www.youtube.com/watch?v=dQw4w9WgXcQ'),
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                'AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
          },
        );
        jsUrl = _extractPlayerUrl(watchResp.body);
        log.writeln('Found player JS: ${jsUrl ?? 'not found'}');
      } catch (e) {
        log.writeln('Watch page fetch error: $e');
      }
    }

    if (jsUrl == null) return null;

    log.writeln('Fetching $jsUrl');
    try {
      final jsResp = await http.get(
        Uri.parse(jsUrl),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
              'AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
        },
      );
      if (jsResp.statusCode != 200) {
        log.writeln('Player JS HTTP ${jsResp.statusCode}');
        return null;
      }
      final ops = _parseCipherOps(jsResp.body, log);
      if (ops != null) {
        _cachedCipherOps = ops;
        _cachedPlayerUrl = jsUrl;
      }
      return ops;
    } catch (e) {
      log.writeln('Player JS fetch error: $e');
      return null;
    }
  }

  /// Parses the YouTube base.js to extract the cipher transform operations.
  ///
  /// YouTube obfuscates the signature with a chain of 3 operations:
  ///   • reverse  – reverses the string
  ///   • splice   – removes N chars from the start
  ///   • swap     – swaps char at index 0 with char at index N
  List<_CipherOp>? _parseCipherOps(String js, StringBuffer log) {
    // 1. Find the main decipher function name
    //    e.g.  a.set("alr","yes");c&&d(decodeURIComponent(Xx(a)))
    //    or    .sig||Xx(a.s)
    final fnNameRe = RegExp(r'\.sig\s*\|\|\s*([a-zA-Z0-9$]+)\(');
    var m = fnNameRe.firstMatch(js);
    if (m == null) {
      // alternative pattern
      final re2 = RegExp(
        r'a\.[a-zA-Z]\s*=\s*([a-zA-Z0-9$]{2,})\(decodeURIComponent',
      );
      m = re2.firstMatch(js);
    }
    if (m == null) {
      log.writeln('  cipher: could not find decipher fn name');
      return null;
    }
    final fnName = m.group(1)!;
    log.writeln('  cipher fn: $fnName');

    // 2. Extract the body of that function
    final escapedName = RegExp.escape(fnName);
    final fnBodyRe = RegExp('$escapedName=function\\([a-zA-Z]\\)\\{([^}]+)\\}');
    final fnMatch = fnBodyRe.firstMatch(js);
    if (fnMatch == null) {
      log.writeln('  cipher: could not find fn body for $fnName');
      return null;
    }
    final fnBody = fnMatch.group(1)!;
    log.writeln('  cipher body: $fnBody');

    // 3. Find the helper object name (e.g. "Ax" in "Ax.reverse(a,...)")
    final helperRe = RegExp(r'([a-zA-Z0-9$]{2,})\.[a-zA-Z0-9$]+\(');
    final helperMatch = helperRe.firstMatch(fnBody);
    if (helperMatch == null) {
      log.writeln('  cipher: could not find helper object name');
      return null;
    }
    final helperName = helperMatch.group(1)!;
    log.writeln('  cipher helper: $helperName');

    // 4. Extract the helper object definition to identify which method = which op
    final escapedHelper = RegExp.escape(helperName);
    final helperObjRe = RegExp('var $escapedHelper=\\{([\\s\\S]+?)\\};');
    final helperMatch2 = helperObjRe.firstMatch(js);
    if (helperMatch2 == null) {
      log.writeln('  cipher: could not find helper object body');
      return null;
    }
    final helperBody = helperMatch2.group(1)!;

    // Map method name → op type by looking at what the method body does
    final methodMap = <String, _OpType>{};
    final methodRe = RegExp(r'([a-zA-Z0-9$]+):function\([^)]*\)\{([^}]+)\}');
    for (final mm in methodRe.allMatches(helperBody)) {
      final name = mm.group(1)!;
      final body = mm.group(2)!;
      if (body.contains('reverse'))
        methodMap[name] = _OpType.reverse;
      else if (body.contains('splice'))
        methodMap[name] = _OpType.splice;
      else if (body.length < 60)
        methodMap[name] = _OpType.swap;
      // swap bodies are short: a.splice(0,1,a[b%a.length]);a[b%a.length]=a[0]...
    }
    log.writeln('  cipher methods: $methodMap');

    // 5. Parse each call in the function body into a _CipherOp
    final ops = <_CipherOp>[];
    final callRe = RegExp(
      '${RegExp.escape(helperName)}\\.([a-zA-Z0-9\$]+)\\([^,]+,([0-9]+)\\)',
    );
    for (final cm in callRe.allMatches(fnBody)) {
      final method = cm.group(1)!;
      final arg = int.tryParse(cm.group(2)!) ?? 0;
      final opType = methodMap[method];
      if (opType != null) ops.add(_CipherOp(opType, arg));
    }

    // Also catch zero-arg reverse calls
    final reverseRe = RegExp(
      '${RegExp.escape(helperName)}\\.([a-zA-Z0-9\$]+)\\([^)]+\\)',
    );
    for (final cm in reverseRe.allMatches(fnBody)) {
      final method = cm.group(1)!;
      if (methodMap[method] == _OpType.reverse &&
          !ops.any((o) => o.type == _OpType.reverse)) {
        ops.add(_CipherOp(_OpType.reverse, 0));
      }
    }

    log.writeln(
      '  cipher ops: ${ops.map((o) => '${o.type.name}(${o.arg})').join(', ')}',
    );
    return ops.isEmpty ? null : ops;
  }

  // ─── Apply cipher ops to a signatureCipher value ─────────────────────────

  String? _decipher(String signatureCipher, List<_CipherOp> ops) {
    // signatureCipher is URL-encoded: "s=<sig>&sp=sig&url=<url>"
    final params = Uri.splitQueryString(signatureCipher);
    final rawSig = params['s'];
    final sigParam = params['sp'] ?? 'signature';
    final baseUrl = params['url'];
    if (rawSig == null || baseUrl == null) return null;

    var sig = rawSig.split('');
    for (final op in ops) {
      switch (op.type) {
        case _OpType.reverse:
          sig = sig.reversed.toList();
        case _OpType.splice:
          sig = sig.sublist(op.arg);
        case _OpType.swap:
          final n = op.arg % sig.length;
          final tmp = sig[0];
          sig[0] = sig[n];
          sig[n] = tmp;
      }
    }

    final decodedUrl = Uri.decodeFull(baseUrl);
    return '$decodedUrl&$sigParam=${sig.join('')}';
  }

  /// Pick the best audio-only URL from a list of plain (non-ciphered) formats.
  String? _pickBestAudioUrl(List all, {required bool plain}) {
    final audio = <Map<String, dynamic>>[];
    for (final f in all) {
      final fmt = f as Map<String, dynamic>;
      final mime = fmt['mimeType']?.toString() ?? '';
      if (plain && fmt.containsKey('url') && mime.contains('audio')) {
        audio.add(fmt);
      }
    }
    if (audio.isEmpty) return null;
    audio.sort((a, b) {
      final aBr = (a['bitrate'] as num?)?.toInt() ?? 0;
      final bBr = (b['bitrate'] as num?)?.toInt() ?? 0;
      return bBr.compareTo(aBr);
    });
    final m4a = audio.where((f) {
      final mime = f['mimeType']?.toString() ?? '';
      return mime.contains('mp4a.40.2') || mime.contains('audio/mp4');
    }).toList();
    final chosen = m4a.isNotEmpty ? m4a.first : audio.first;
    return chosen['url'] as String?;
  }

  /// Decipher and pick the best audio URL from a list of ciphered formats.
  String? _decipherBestAudio(List all, List<_CipherOp> ops, StringBuffer log) {
    final audio = <Map<String, dynamic>>[];
    for (final f in all) {
      final fmt = f as Map<String, dynamic>;
      final mime = fmt['mimeType']?.toString() ?? '';
      final cipher = fmt['signatureCipher'] ?? fmt['cipher'];
      if (cipher != null && mime.contains('audio')) audio.add(fmt);
    }

    // Also try mixed formats if no audio-only ones
    if (audio.isEmpty) {
      for (final f in all) {
        final fmt = f as Map<String, dynamic>;
        final cipher = fmt['signatureCipher'] ?? fmt['cipher'];
        if (cipher != null) audio.add(fmt);
      }
    }

    if (audio.isEmpty) return null;

    audio.sort((a, b) {
      final aBr = (a['bitrate'] as num?)?.toInt() ?? 0;
      final bBr = (b['bitrate'] as num?)?.toInt() ?? 0;
      return bBr.compareTo(aBr);
    });

    final m4a = audio.where((f) {
      final mime = f['mimeType']?.toString() ?? '';
      return mime.contains('mp4a.40.2') || mime.contains('audio/mp4');
    }).toList();

    final candidates = m4a.isNotEmpty ? m4a : audio;

    for (final fmt in candidates) {
      final cipher = fmt['signatureCipher'] ?? fmt['cipher'];
      final url = _decipher(cipher as String, ops);
      if (url != null) {
        log.writeln(
          '  ✅ deciphered: ${fmt['bitrate']} bps | ${fmt['mimeType']}',
        );
        return url;
      }
    }
    return null;
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

// ─── Cipher types ─────────────────────────────────────────────────────────────

enum _OpType { reverse, splice, swap }

class _CipherOp {
  final _OpType type;
  final int arg;
  const _CipherOp(this.type, this.arg);
}
