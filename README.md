# ShadowTrim

**ShadowTrim** (ShadowClip) is a Flutter-based desktop video trimmer built for speed and quality. Using **lossless trimming** (stream copy) via FFmpeg, ShadowTrim cuts videos without any re-encoding — the result is fast, with zero quality loss.

It's perfect for quickly trimming multiple clips (gameplay highlights, OBS recordings, raw footage, etc.) without having to open a heavy video editing suite.

---

## Key Features

- **Drag & Drop** — Simply drag video files (or an entire folder) into the app window.
- **Import File / Folder** — Open a single clip, multiple clips at once, or an entire folder's contents.
- **Lossless Trim** — Video cutting via `ffmpeg -c copy`, no re-encoding, so processing is instant and video quality is 100% preserved.
- **Clip Management** — The active clip list can be sorted by Name, File Size, Date Modified, or Date Created.
- **Precise Cut Points** — Set start and end points directly from the video playhead, with a visual range slider.
- **Flexible Export Settings**
  - Manually rename the output file.
  - Choose a custom destination folder.
  - Option to auto-create a `Trimmed/` subfolder.
  - Option to preserve the original file's date metadata (Created/Modified Date), with dedicated Windows support via PowerShell.
- **Thumbnail Preview** — Every clip in the list shows an automatically generated thumbnail.
- **Delete Clip** — Delete a file directly from disk with a safety confirmation dialog.
- **Keyboard Controls** — Full navigation and playback control without needing a mouse.
- **Modern Dark UI** — A custom dark theme with an "Nvidia Green" accent.

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

---

## Dependencies

Before running this app, make sure you have:
1. **Flutter SDK**
2. **Flutter desktop support**
3. **FFmpeg** 
> **Important:** This app **will not work** without FFmpeg installed, since the entire video-trimming process relies entirely on the `ffmpeg` binary being called from the system.

---

## Installation

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
   - Use the `[` and `]` keyboard shortcuts (see the table below).

4. **Configure Export Settings** (right panel)
   - Rename the output file.
   - Choose a destination folder (optional — defaults to the original file's location).
   - Toggle the option to auto-create a `Trimmed/` subfolder.
   - Toggle the option to preserve the file's date metadata.

5. **Click "Export Trimmed Video"** — the video will be losslessly trimmed and saved to the destination.

---

## Keyboard Shortcuts

| Key | Function |
|---|---|
| `Space` / `K` / Click | Play / Pause |
| `←` / `→` | Seek video 1 second back/forward |
| `J` / `L` | Seek video 5 seconds back/forward |
| `[` | Set **Start** cut point to the current playhead position |
| `]` | Set **End** cut point to the current playhead position |
| `↑` / `↓` | Go to Previous / Next clip |
| `Enter` | Run the Export/Trim process |
| `1` / `2` / `3` | Jump the playhead to 25% / 50% / 75% of the video duration |

---

## Notes & Limitations

- Because it uses `-c copy` mode (no re-encoding), FFmpeg **snaps cut points to the nearest keyframe**. This is normal for lossless trimming and is the trade-off for fast processing without quality loss.
- The "preserve creation time" feature on Windows requires PowerShell, which is available by default on the system.
- Native drag & drop and file picker only work on **desktop** targets (Windows/macOS/Linux) — web/mobile are not supported yet.

---

## License

Distributed under the MIT License. See the `LICENSE` file for more information.

---

<p align="center">Made with Flutter & FFmpeg</p>
