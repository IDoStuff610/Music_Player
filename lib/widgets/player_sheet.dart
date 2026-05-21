import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:music_player/services/audio_player_service.dart';

class PlayerSheet extends StatefulWidget {
  const PlayerSheet({super.key});

  @override
  State<PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<PlayerSheet>
    with SingleTickerProviderStateMixin {
  final _service = AudioPlayerService();
  bool _isExpanded = true;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        if (_service.currentItem == null) return const SizedBox.shrink();
        return _isExpanded ? _buildFullPlayer() : _buildMiniPlayer();
      },
    );
  }

  Widget _buildMiniPlayer() {
    final item = _service.currentItem!;
    return GestureDetector(
      onTap: () => setState(() => _isExpanded = true),
      child: Container(
        height: 64,
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(12),
                bottomLeft: Radius.circular(12),
              ),
              child: item.thumbnailUrl != null
                  ? Image.network(
                      item.thumbnailUrl!,
                      width: 64,
                      height: 64,
                      fit: BoxFit.cover,
                    )
                  : Container(
                      width: 64,
                      height: 64,
                      color: Colors.grey.shade800,
                      child: const Icon(Icons.music_note, color: Colors.grey),
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (item.subtitle != null)
                    Text(
                      item.subtitle!,
                      style: const TextStyle(color: Colors.grey, fontSize: 11),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            StreamBuilder<PlayerState>(
              stream: _service.playerStateStream,
              builder: (context, snapshot) {
                final isPlaying = snapshot.data?.playing ?? false;
                final isLoading =
                    _service.isLoading ||
                    snapshot.data?.processingState == ProcessingState.loading ||
                    snapshot.data?.processingState == ProcessingState.buffering;
                return IconButton(
                  onPressed: _service.togglePlayPause,
                  icon: isLoading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : Icon(
                          isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                          size: 28,
                        ),
                );
              },
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }

  Widget _buildFullPlayer() {
    final item = _service.currentItem!;
    return Container(
      color: Colors.black,
      child: SafeArea(
        child: Column(
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() => _isExpanded = false),
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      'Now Playing',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),

            const Spacer(),

            // Album art
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 40),
              child: AspectRatio(
                aspectRatio: 1,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: item.thumbnailUrl != null
                      ? Image.network(item.thumbnailUrl!, fit: BoxFit.cover)
                      : Container(
                          color: Colors.grey.shade800,
                          child: const Icon(
                            Icons.music_note,
                            color: Colors.grey,
                            size: 80,
                          ),
                        ),
                ),
              ),
            ),

            const Spacer(),

            // Title + artist
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  Text(
                    item.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  if (item.subtitle != null)
                    Text(
                      item.subtitle!,
                      style: const TextStyle(color: Colors.grey, fontSize: 14),
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            ),

            // Error / debug panel with copy button
            if (_service.error != null || _service.debugInfo != null)
              _buildDebugPanel(context),

            const SizedBox(height: 24),

            // Progress bar
            StreamBuilder<Duration?>(
              stream: _service.durationStream,
              builder: (context, durationSnap) {
                final duration = durationSnap.data ?? Duration.zero;
                return StreamBuilder<Duration>(
                  stream: _service.positionStream,
                  builder: (context, posSnap) {
                    final position = posSnap.data ?? Duration.zero;
                    final clamped = position > duration ? duration : position;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: Column(
                        children: [
                          Slider(
                            value: clamped.inMilliseconds.toDouble(),
                            max: duration.inMilliseconds.toDouble(),
                            activeColor: Colors.white,
                            inactiveColor: Colors.grey.shade700,
                            onChanged: (v) => _service.seekTo(
                              Duration(milliseconds: v.toInt()),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _formatDuration(clamped),
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                                Text(
                                  _formatDuration(duration),
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),

            const SizedBox(height: 16),

            // Controls
            StreamBuilder<PlayerState>(
              stream: _service.playerStateStream,
              builder: (context, snapshot) {
                final isPlaying = snapshot.data?.playing ?? false;
                final isLoading =
                    _service.isLoading ||
                    snapshot.data?.processingState == ProcessingState.loading ||
                    snapshot.data?.processingState == ProcessingState.buffering;
                return Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    GestureDetector(
                      onTap: _service.togglePlayPause,
                      child: Container(
                        width: 64,
                        height: 64,
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                        ),
                        child: isLoading
                            ? const Padding(
                                padding: EdgeInsets.all(16),
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black,
                                ),
                              )
                            : Icon(
                                isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.black,
                                size: 36,
                              ),
                      ),
                    ),
                  ],
                );
              },
            ),

            const Spacer(),
          ],
        ),
      ),
    );
  }

  /// Error + debug panel with a copy-to-clipboard icon button.
  Widget _buildDebugPanel(BuildContext context) {
    // Build the full text that will be copied
    final fullText = [
      if (_service.error != null) _service.error!,
      if (_service.debugInfo != null) _service.debugInfo!,
    ].join('\n\n---\n\n');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.35,
        ),
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: _service.error != null
                ? Colors.redAccent.withOpacity(0.5)
                : Colors.grey.shade700,
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Panel toolbar ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 4, 0),
              child: Row(
                children: [
                  Icon(
                    _service.error != null
                        ? Icons.error_outline
                        : Icons.bug_report_outlined,
                    size: 14,
                    color: _service.error != null
                        ? Colors.redAccent
                        : Colors.grey,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _service.error != null ? 'Error' : 'Debug',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _service.error != null
                          ? Colors.redAccent
                          : Colors.grey,
                    ),
                  ),
                  const Spacer(),
                  // ── Copy button ──────────────────────────────────────────
                  _CopyButton(textToCopy: fullText),
                ],
              ),
            ),
            const Divider(color: Colors.white12, height: 10, thickness: 0.5),
            // ── Scrollable content ─────────────────────────────────────────
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_service.error != null)
                      SelectableText(
                        _service.error!,
                        style: const TextStyle(
                          color: Colors.redAccent,
                          fontSize: 11,
                          height: 1.4,
                        ),
                      ),
                    if (_service.error != null && _service.debugInfo != null)
                      const Divider(color: Colors.white12, height: 16),
                    if (_service.debugInfo != null)
                      SelectableText(
                        _service.debugInfo!,
                        style: const TextStyle(
                          color: Colors.yellowAccent,
                          fontSize: 10,
                          height: 1.4,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

// ─── Copy button widget ──────────────────────────────────────────────────────

class _CopyButton extends StatefulWidget {
  final String textToCopy;
  const _CopyButton({required this.textToCopy});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.textToCopy));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _copy,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: _copied
              ? const Row(
                  key: ValueKey('copied'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check, size: 13, color: Colors.greenAccent),
                    SizedBox(width: 4),
                    Text(
                      'Copied',
                      style: TextStyle(fontSize: 11, color: Colors.greenAccent),
                    ),
                  ],
                )
              : const Row(
                  key: ValueKey('copy'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.copy, size: 13, color: Colors.grey),
                    SizedBox(width: 4),
                    Text(
                      'Copy',
                      style: TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
