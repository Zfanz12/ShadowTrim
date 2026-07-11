# Changelog
All notable changes to ShadowTrim will be documented in this file.

## Upcoming Fixes & Features
- **Simplified Default Sorting** — Default clip sorting will switch to Date Created only, replacing the current four-way sort with two direct options: Newest and Oldest.
- **Playback Speed Control** — Added a speed selector (1x, 1.5x, 2x, 3x) placed next to the volume control, adjustable via `Shift + ,` (`<`) and `Shift + .` (`>`). Stepping is non-cyclic and stops at the minimum/maximum speed.
- **Renamed Percentage-Jump Shortcuts** — The playhead jump shortcuts for 25% / 50% / 75% will change from `1 / 2 / 3` to `I / O / P`.
- **Jump to Beginning/End Shortcuts** — `Shift + I` will jump the playhead to the beginning of the video, and `Shift + P` will jump to the end.
- **Mute Toggle Shortcut** — Added `M` as a shortcut to toggle mute/unmute.
- **Volume Adjustment Shortcut** — `Shift + Arrow Up` / `Shift + Arrow Down` will raise/lower the volume, where supported.
- **Improved Delete Button Visibility** — The "Delete" label in the delete confirmation dialog will change from faint red to solid white for better readability.
- **Delete Shortcut & Popup Controls** — Pressing `Del` will open the delete confirmation dialog for the selected clip; inside the dialog, `Enter` confirms the deletion and `Esc` cancels it.
- **"Delete Original Clip" Checkbox** — Added an optional checkbox in the export panel to delete the source file after a successful trim. Unchecked by default, and highlighted in red when checked as a visual warning.
- **Quick Jump to Start Point** — Added a `Shift + J` shortcut, along with a corresponding on-screen button (placed next to the 5-second seek-backward control), to jump the playhead directly to the clip's Start Cut point.

# Releases

## [1.0.0] - 2026-07-11
### Added
- **Multi-Clip Workspace** — Dashboard-style workspace for importing, previewing, and managing multiple video clips in a single session.
- **Drag & Drop Import** — Import single files, multiple files, or an entire folder by dragging them directly into the app window.
- **File & Folder Picker** — Native "Open Clip" and "Open Folder" dialogs supporting `.mp4`, `.mkv`, `.avi`, and `.mov` formats.
- **Clip List Sorting** — Sort the clip list by Name, File Size, Date Modified, or Date Created.
- **Thumbnail Previews** — Automatic thumbnail generation for every clip shown in the list.
- **Integrated Video Player** — Built-in playback powered by `media_kit`, with play/pause, seeking, and scrubbing support.
- **Visual Range Slider** — Custom bracket-style range slider (`[` `]`) for setting Start and End cut points directly on the timeline.
- **Set Start / Set End Buttons** — Set cut points precisely at the current playhead position with dedicated controls.
- **Lossless Trimming** — Trims video using `ffmpeg -c copy` (stream copy), avoiding re-encoding entirely for instant, quality-preserving cuts.
- **Metadata Preservation** — Optionally restores the original file's Modified/Accessed dates on the trimmed output, with dedicated Windows Creation Time support via PowerShell.
- **Custom Export Settings** — Choose a custom output filename and destination folder, plus an option to auto-create a `Trimmed/` subfolder.
- **Delete Clip with Confirmation** — Permanently delete a clip from disk, guarded by a confirmation dialog.
- **Full Keyboard Control** — Shortcuts for playback (`Space` / `K`), seeking (`Arrow Left/Right`, `J` / `L`), setting cut points (`[` `]`), navigating between clips (`Arrow Up/Down`), exporting (`Enter`), and jumping to 25% / 50% / 75% (`1` / `2` / `3`).
- **Single-Clip Quick Trim Flow** — An alternate, lightweight screen for quickly trimming a single dropped video file outside the main workspace.
- **Custom Dark Theme** — Nvidia Green accented dark UI applied consistently across the app.
- **Marquee Filenames** — Long filenames scroll automatically in the clip list for full visibility.

### Internal
- **Initial Release** — Established the foundational architecture using Flutter for desktop (Windows/macOS/Linux), `media_kit` for playback, and FFmpeg for lossless trimming.
