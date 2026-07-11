import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'dart:async';
import '../services/video_service.dart';

class TrimmerScreen extends StatefulWidget {
  final String videoPath;

  const TrimmerScreen({super.key, required this.videoPath});

  @override
  State<TrimmerScreen> createState() => _TrimmerScreenState();
}

class _TrimmerScreenState extends State<TrimmerScreen> {
  late final Player player;
  late final VideoController controller;
  
  Duration _videoDuration = Duration.zero;
  Duration _startPosition = Duration.zero;
  Duration _endPosition = Duration.zero;
  
  bool _isExporting = false;
  String _exportStatus = '';

  @override
  void initState() {
    super.initState();
    // Initialize the player
    player = Player();
    controller = VideoController(player);

    // Load the video file
    player.open(Media(widget.videoPath), play: false);

    // Listen to duration changes to initialize slider
    player.stream.duration.listen((duration) {
      if (duration != null && duration > Duration.zero) {
        setState(() {
          _videoDuration = duration;
          if (_endPosition == Duration.zero) {
            _endPosition = duration;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    player.dispose();
    super.dispose();
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "${twoDigits(duration.inHours)}:$twoDigitMinutes:$twoDigitSeconds";
  }

  Future<void> _exportVideo() async {
    setState(() {
      _isExporting = true;
      _exportStatus = 'Trimming video losslessly...';
    });

    final outputPath = await VideoTrimmer.trimVideo(
      inputPath: widget.videoPath,
      startTime: _formatDuration(_startPosition),
      endTime: _formatDuration(_endPosition),
    );

    setState(() {
      _isExporting = false;
    });

    if (mounted) {
      if (outputPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export successful! Saved at: $outputPath'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to export video. Check logs.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Trim Video'),
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Video(
                  controller: controller,
                  controls: AdaptiveVideoControls,
                ),
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(24.0),
            color: Theme.of(context).colorScheme.surface,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Start: ${_formatDuration(_startPosition)}'),
                    Text('End: ${_formatDuration(_endPosition)}'),
                  ],
                ),
                const SizedBox(height: 8),
                if (_videoDuration > Duration.zero)
                  RangeSlider(
                    values: RangeValues(
                      _startPosition.inMilliseconds.toDouble(),
                      _endPosition.inMilliseconds.toDouble(),
                    ),
                    min: 0,
                    max: _videoDuration.inMilliseconds.toDouble(),
                    activeColor: Theme.of(context).colorScheme.primary,
                    inactiveColor: Colors.grey.shade800,
                    onChanged: (values) {
                      setState(() {
                        _startPosition = Duration(milliseconds: values.start.toInt());
                        _endPosition = Duration(milliseconds: values.end.toInt());
                      });
                      
                      // Seek to start position when start handle moves
                      if (player.state.position != _startPosition) {
                         player.seek(_startPosition);
                      }
                    },
                  ),
                const SizedBox(height: 16),
                _isExporting
                    ? Column(
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 8),
                          Text(_exportStatus),
                        ],
                      )
                    : ElevatedButton.icon(
                        onPressed: _exportVideo,
                        icon: const Icon(Icons.cut),
                        label: const Text('Export Trimmed Video'),
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(double.infinity, 50),
                          textStyle: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
