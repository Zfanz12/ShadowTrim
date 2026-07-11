import 'package:flutter/material.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'trimmer_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isDragging = false;

  void _openFilePicker() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['mp4', 'mkv', 'avi', 'mov'],
      );

      if (result != null && result.files.single.path != null) {
        _navigateToTrimmer(result.files.single.path!);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to open file picker: $e')),
        );
      }
    }
  }

  void _navigateToTrimmer(String filePath) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => TrimmerScreen(videoPath: filePath),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ShadowClip Trimmer'),
        centerTitle: true,
      ),
      body: Center(
        child: DropTarget(
          onDragDone: (detail) {
            if (detail.files.isNotEmpty) {
              final file = detail.files.first;
              // Simple check for video extension
              if (file.path.endsWith('.mp4') || file.path.endsWith('.mkv') || file.path.endsWith('.avi')) {
                _navigateToTrimmer(file.path);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please select a valid video file (.mp4, .mkv, .avi)')),
                );
              }
            }
          },
          onDragEntered: (detail) {
            setState(() {
              _isDragging = true;
            });
          },
          onDragExited: (detail) {
            setState(() {
              _isDragging = false;
            });
          },
          child: Container(
            width: 400,
            height: 300,
            decoration: BoxDecoration(
              color: _isDragging ? Theme.of(context).colorScheme.surface.withOpacity(0.8) : Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _isDragging ? Theme.of(context).colorScheme.primary : Colors.grey.shade800,
                width: 2,
                style: BorderStyle.solid,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.upload_file,
                  size: 64,
                  color: _isDragging ? Theme.of(context).colorScheme.primary : Colors.grey,
                ),
                const SizedBox(height: 16),
                Text(
                  'Drag and drop video here',
                  style: TextStyle(
                    fontSize: 18,
                    color: _isDragging ? Theme.of(context).colorScheme.primary : Colors.white70,
                  ),
                ),
                const SizedBox(height: 24),
                const Text('OR', style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _openFilePicker,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Browse Files'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
