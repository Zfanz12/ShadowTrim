# ShadowTrim

**ShadowTrim** is a Flutter-based desktop video trimmer built for speed and quality. Using stream copy via FFmpeg, ShadowTrim cuts clips without any re-encoding or re-rendering. The result is instant, with zero quality loss.

It's perfect for quickly trimming multiple clips (gameplay highlights, OBS recordings, raw footage, etc.) without having to open a heavy video editing suite.

---

[Key Features](#key-features) • [How to Use](#how-to-use) • [Keyboard Shortcuts](#keyboard-shortcuts) • [Tech Stack](#tech-stack) • [Changelog](CHANGELOG.md)

---

## Key Features

- **Drag & Drop** — Simply drag video files (or folders) directly into the app window to load them.
- **Instant Lossless Trim** — Cuts videos instantly using FFmpeg stream copy (`-c copy`) with zero quality loss and no rendering time.
- **Workspace Sidebar Groups** — Organizes your clips into visual folders: *Untrimmed* (queue), *Trimmed* (completed), and *Deleted* (flagged for cleanup).
- **Trim Revision** — Revise, re-trim, and tweak already trimmed clips at any time.
- **Session Auto-Resume** — Save your progress on exit. The app automatically recovers your active clips, cut points, renames, and flags on the next launch.
- **Advanced Playback & Hotkeys** — Change playback speed (up to 3x) and navigate or set cut points entirely using keyboard shortcuts.

---

## Tech Stack

| Component | Technology |
|---|---|
| Framework | [Flutter](https://flutter.dev) (Dart) — Desktop (Windows / macOS / Linux) |
| Video Playback | [`media_kit`](https://pub.dev/packages/media_kit) & [`media_kit_video`](https://pub.dev/packages/media_kit_video) |
| Video Trimming | [FFmpeg](https://ffmpeg.org/) (invoked via `Process.run`, external system dependency) |
| Drag & Drop | [`desktop_drop`](https://pub.dev/packages/desktop_drop) |
| File Picker | [`file_picker`](https://pub.dev/packages/file_picker) |
| Path Utilities | [`path`](https://pub.dev/packages/path) |
| Window Close | [`flutter_window_close`](https://pub.dev/packages/flutter_window_close) |

---

## Dependencies

Before running this app, make sure you have:
1. **Flutter SDK**
2. **Flutter desktop support**
3. **FFmpeg** 
> **Important:** This app **will not work** without FFmpeg installed, since the entire video-trimming process relies entirely on the `ffmpeg` binary being called from the system.

---

## Installation

Download from the latest version on Releases 
OR
1. **Clone the repository**
   ```bash
   git clone https://github.com/username/shadowtrim.git
   cd shadowtrim
   ```

2. **Install dependencies**
   ```bash
   flutter pub get
   ```

3. **Run the app** (choose based on your platform)
   ```bash
   flutter run -d windows
   # or
   flutter run -d macos
   # or
   flutter run -d linux
   ```

### Building for Production

```bash
flutter build windows   # produces .exe in build/windows/runner/Release
flutter build macos     # produces .app in build/macos/Build/Products/Release
flutter build linux     # produces a binary in build/linux/x64/release/bundle
```

---

## How to Use

1. **Import a Video**
   - Drag a video file directly into the app window, **or**
   - Click **"Open Clip"** to select one or more files, **or**
   - Click **"Open Folder"** to load every video in a folder at once.

   Supported formats: `.mp4`, `.mkv`, `.avi`, `.mov`

2. **Select a Clip** from the left sidebar to load it into the video player.

3. **Set Cut Points**
   - Play the video and use the range slider below the player, **or**
   - Use the **Set Start** / **Set End** buttons at the current playhead position, **or**
   - Use the `[` and `]` keyboard shortcuts.

4. **Configure Export Settings** (right panel)
   - Rename the output file.
   - Choose a destination folder (optional — defaults to the original file's location).
   - Toggle the option to auto-create a `Trimmed/` subfolder.
   - Toggle the option to preserve the file's date metadata (Created/Modified).
   - Toggle "Delete original clip" (soft-deletes the source clip when trimmed).

5. **Click "Export Trimmed Video"** (or press `Enter`) — the clip will be losslessly trimmed and saved to the destination.

---

## Keyboard Shortcuts

| Key | Function |
|---|---|
| `Space` / `K` | Play / Pause |
| `←` / `→` | Seek video 1 second back/forward |
| `J` / `L` | Seek video 5 seconds back/forward |
| `[` | Set **Start** cut point to the current playhead position |
| `]` | Set **End** cut point to the current playhead position |
| `↑` / `↓` | Go to Previous / Next clip (follows visual list order) |
| `Enter` | Run the Export/Trim process / Save rename (when renaming) |
| `I` / `O` / `P` | Jump the playhead to 25% / 50% / 75% of the video duration |
| `Shift + I` / `Shift + P` | Jump the playhead to the absolute beginning / end of the video |
| `Shift + J` / `Shift + L` | Jump the playhead to the current Start / End cut points |
| `Shift + ,` (`<`) / `Shift + .` (`>`) | Decrease / Increase playback speed (1x, 1.5x, 2x, 3x) |
| `Shift + ↑` / `Shift + ↓` | Increase / Decrease volume |
| `M` | Mute / Unmute audio |
| `F2` | Rename export file (focuses text field; press `Enter` to save) |
| `Delete` | Flag the selected clip for deletion |

---

## Notes & Limitations

- Because it uses `-c copy` mode (no re-encoding), FFmpeg **snaps cut points to the nearest keyframe**. This is normal for lossless trimming and is the trade-off for fast processing without quality loss.
- The "preserve creation time" feature on Windows requires PowerShell, which is available by default on the system.

---

## Changelog

For a detailed history of all features, enhancements, and fixes, please check the [CHANGELOG.md](CHANGELOG.md) file.

---

## License

Distributed under the MIT License. See the `LICENSE` file for more information.

---

<p align="center">Made with Flutter & FFmpeg</p>
