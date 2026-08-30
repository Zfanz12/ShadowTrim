# Changelog

All notable changes to ShadowTrim will be documented in this file.

# Releases

## [2.2.0] - 2026-08-29

### New Features & Core Architecture

**Major:**
* **C++ Native Core Engine (`shadowtrim_core.dll`)** — Migrated core system and file operations to native C++ compiled directly alongside the Windows binary.
* **Dart FFI Interop Bridge (`dart:ffi`)** — Implemented zero-overhead direct memory & function calls between Flutter UI and the C++ Core engine.
* **Instant Win32 File Timestamp Preservation** — Replaced slow PowerShell subprocess invocations (500–1000 ms) with native Win32 `GetFileTime` and `SetFileTime` kernel APIs (< 0.01 ms), accelerating batch export completion by up to 10,000x for metadata operations.
* **Direct High-Priority Process Pipeline** — Direct Win32 `CreateProcessW` execution without shell overhead for trimming and video probing.
* **Resilient Dual-Engine Fallback** — Added graceful automatic fallback to standard Dart engine for test and non-Windows environments.

---

## [2.1.2] - 2026-08-01

### New Features & Core Logic

**Major:**
* **System Logging Implementation** — Added a comprehensive internal logging system. The application now generates and stores local `.log` files to track events, background processes, file operations, and crash reports, making future troubleshooting and debugging significantly easier. You can check it on 'C:\Users\(yourUsername)\Documents\ShadowTrim\logs'!.

### Bug Fixes & Performance Enhancements

**Major:**
* **Hardware Codec Configuration** — Updated the underlying video player configurations for improved and supported more codec and stability also performance
* **Fix App Crash on Fresh Folder Load** — Fixed a critical bug where opening a new folder upon a fresh start would cause the application to immediately stop responding and crash.
* **Optimize 'Open Folder' Execution** — Significantly improved the response time when clicking any "Open Folder" buttons.
* **Fix File's Duration Display** — Fixed a bug where the duration of videos in the file list would remain stuck on "loading" and only reveal the actual time after the user manually selected the clip.

**Minor:**
* **Fix Metadata Text Overflow** — Fixed an issue where long text in the "Quality" metadata field overflowed, fixing it by adding a horizontal scrolling effect.

### Quality of Life (QoL) & UI/UX Improvements

**Major:**
* **Loading Overlay** — Added a visual loading overlay in the video player area when first opening or changing folders. This indicator ensures users know the video is buffering and prevents premature playback actions.
* **Collapsible Side Panels** — The "Metadata Information" and "Shortcuts" panels are now collapsible to save screen space. By default, the Metadata panel remains open, while the Shortcuts panel is collapsed.

**Minor:**
* **Added 0.25x Playback Speed** — Further expanded the playback speed controls by adding a `0.25x`.
* **Shortcut Panel Icon Update** — Changed the icon for the "Shortcuts" panel to a keyboard icon to better represent its function.
* **Comprehensive Hover Effects** — Added missing hover state animations across various UI elements to provide consistent visual feedback.
* **Metadata Layout Adjustment** — Swapped the visual positions of the "Size" and "Duration" fields within the metadata information panel.

---

## [2.1.1] - 2026-07-28

### Bug Fixes & Performance Enhancements

**Major:**
- **Parallel File Scanning (`Future.wait`)** — Converted file scanning from sequential (one-by-one) to parallel processing. Opening a folder now reads all clip metadata concurrently in a single pass, dramatically cutting folder import loading times.
- **Fix Heavy Folder Switching Crash & Rate-Limited Thumbnail Queue** — Fixed a crash when opening or switching to folders containing many heavy videos (e.g., from `Downloads` to a heavy `Videos` folder). Implemented a concurrency-limited queue (max 2 concurrent FFmpeg thumbnail processes) to prevent CPU, disk I/O, and process pool exhaustion, along with automatic queue clearing and media player teardown (`_player.stop()`) when switching workspaces.
- **Fix 0x8001010e COM Thread Error** — Replaced heavy `media_kit` `Player` instances in clip list thumbnails with a lightweight FFmpeg JPEG image cache, eliminating dozens of concurrent native background COM/D3D threads that caused Win32 `RPC_E_WRONG_THREAD` crashes.
- **Import Safety Lock (`_isImporting`)** — Added a state lock during file/folder imports to reject new import requests while one is active, preventing race conditions, state collisions, and UI crashes.
- **Fix "All Flagged to Delete" Workspace Bug** — Fixed a critical bug where flagging all videos for deletion without trimming any clips caused the workspace to instantly appear completely empty, instead of correctly showing 0 trimmed, 0 untrimmed, and the flagged clips. Also fixed workspace duplication when re-opening a folder in this state.
- **Fix Mass Export Corruption Bug** — Fixed a critical issue when trimming a large batch of clips (e.g., up to 50 clips) where the trimming process would abruptly halt, files would fail to move to the "Trimmed" folder, and exports were corrupted. Resolved by adding a force-overwrite flag (`-y`) to the FFmpeg command.
- **Smart Dynamic 3x Playback Speed** — `3.0x` playback speed is now dynamically enabled for standard videos (<= 60 FPS) where hardware decoding is smooth, but automatically capped at `2.0x` max for high-framerate clips (> 60 FPS, e.g. 120 FPS Shadowplay footage) to prevent GPU decoding bottlenecks and stuttering.
- **~50% Application Size Reduction** — Reduced portable/installer application size from ~68MB down to ~32MB by replacing heavy native video player instances in list thumbnails with lightweight image caching, enabling aggressive Flutter AOT tree-shaking and dead code elimination.

**Minor:**
- **FilePicker COM Retry Guard** — Added retry handling for `FilePicker` dialog calls to gracefully handle transient Windows COM thread marshalling delays during folder selection.

### Quality of Life (QoL) & UI/UX Improvements

**Minor:**
- **App Header Rename** — Changed the main application window title from `shadowclip_trimmer` to `ShadowTrim`.
- **About Menu Version Update** — Updated the version number displayed in the "About" menu to show correct version.
- **Cleaned Metadata Display** — Removed the "Cut Start" and "Cut End" information from the metadata display to declutter the user interface.
- **Detailed Quality Metadata Display** — Added a new "Quality" row in the Video Metadata card showing the video's Resolution, FPS, and Bitrate in a single line (e.g., `1920x1080 • 120 FPS • 15.0 Mbps`).
- **Centered Window on Launch** — The application window now opens centered on screen instead of the top-left corner.
- **Increased Default Window Height (960px)** — Increased default window launch height to 960 pixels (1280x960) to provide ample screen real estate and eliminate UI overflow.

---

## [2.1.0] - 2026-07-27

### Session Management System

**Minor:**
- **End Session Loading Animation** — Added a visual loading animation when clicking "End This Session" to clearly indicate that the background deletion process is running and to ensure the app does not appear frozen to the user.

### Quality of Life (QoL) & UI/UX Improvements

**Minor:**
- **Expanded Playback Speed Control** — Added a new `0.5x` playback speed option to the speed selector, allowing for slower and more precise video review.
- **Sort by File Size** — Added a new sorting feature allowing users to arrange their video list by file size ("Biggest" and "Smallest").
- **Quick Folder Access** — Added an "Open Folder" icon directly in the header/file path area for quick and easy access to the clip's directory in the system file explorer.
- **Global Cursor Pointer** — Updated the CSS/UX globally so the cursor now consistently changes to a pointer (hand icon) when hovering over any clickable button across the entire application.

---

## [2.0.0] - 2026-07-12

### Bug Fixes & Performance Enhancements

**Major:**
- **Fix Duplicate Trimmed Revision Bug** — Fixed a bug causing duplicate entries to be created when a trimmed clip is revised.
- **Fix Missing Session-Exit Save Prompt** — Fixed a bug where the "Save Session" popup sometimes failed to appear when exiting the app.
- **Fix Missing Trim Markers After Session Reload** — Fixed a bug where, after closing and reloading a previous session, clips in the Trimmed group that were in a "trimmed but not yet revised" state didn't show their seek bar and trim markers in the preview.
- **Fix Arrow-Key Navigation Inconsistency** — Fixed a bug where navigating the clip list with Arrow Up/Down didn't move through clips consistently.
- **Fix Rename Duplicating Trimmed File** — Fixed a bug where renaming a clip that's already in the Trimmed group created a duplicate file in the output folder instead of renaming/replacing the existing trimmed file.

**Minor:**
- **Resolve List Scrolling Lag** — Fixed a performance issue where scrolling down the video list accidentally loaded all videos simultaneously, causing the application to lag. Implemented lazy loading and optimized rendering.
- **Duplicate Filename Handling** — Implemented a safeguard for duplicate file names. If a name already exists, the app prompts a rename popup or automatically appends a sequence number (e.g., "filename (2)").

### New Features & Core Logic

**Major:**
- **Recycle Bin Integration & Delete Flow Rework** — Deleted files are now moved to the system Recycle Bin instead of being permanently deleted. Clicking "Delete Clip" no longer deletes immediately — it flags the clip for deletion, and the actual move to Recycle Bin only executes when the user selects "End This Session."
- **"Deleted" Group in Sidebar** — Added a new "Deleted" group in the left sidebar, placed below "Untrimmed." Works the same way as other groups; clips flagged for deletion appear here until the session ends and the deletion is executed.
- **Revise Trimmed Clip** — Added the ability to revise/re-trim a clip that has already been trimmed, instead of only being able to trim it once.
- **"Delete Original Clip" Checkbox** — Added an optional checkbox in the export panel to delete the source file after a successful trim. Unchecked by default, and highlighted in red when checked as a visual warning.

**Minor:**
- **Rename Reflects in Trimmed Output** — When a clip's filename is changed, the new name is now correctly shown on the trimmed version, instead of still displaying the original filename.
- **Flag Icon for "Delete Original Clip"** — Added an icon on clips in the Trimmed group that are flagged to have their original file deleted, so it's clear at a glance which clips are marked.

### Session Management System

**Major:**
- **Session Memory Management** — A blacklist file tracks previously trimmed video names so they don't reappear in the active list, even if "Delete file after trim" is unchecked. If the user chooses "Save" on the exit prompt, the blacklist is written; if the user chooses "Delete this session," the blacklist is not saved.
- **Session Save Prompt on Exit** — Added a confirmation dialog when closing the app with an active session, offering three options: "Save," "Delete this session," and "Cancel."
- **Resume Session After Restart** — Users can now close the app and continue a previous session later without losing their progress.

**Minor:**
- **"End This Session" Button** — Added a button to manually end/wrap up the current session (e.g., once tidying up clips is done), which also triggers execution of any pending flagged deletions.

### Quality of Life (QoL) & UI/UX Improvements

**Major:**
- **Playback Speed Control** — Added a speed selector (1x, 1.5x, 2x, 3x) placed next to the volume control.

**Minor:**
- **Simplified Default Sorting** — Removed the "Date Modified" sort option. Default sorting is now Date Created only, with "Newest" and "Oldest" as the two available options.
- **Auto-Advance on Trim** — The app now automatically proceeds to the next video in the list immediately after the user presses `Enter` to execute a trim.
- **Auto-Scroll Video List** — The left sidebar video list now automatically scrolls as the user navigates, keeping the currently selected video visible on screen.
- **Accurate "Show in Folder" Routing** — The "Show in Folder" icon for trimmed clips now directs the user to the newly generated file rather than the original video.
- **Improved Delete Button Visibility** — The "Delete" label in the delete confirmation dialog changed from faint red to solid white for better readability.
- **Success Notification Styling** — The "Clip deleted successfully" toast notification at the bottom of the screen changed to a red background, with the text in white, semibold font for better readability.
- **Quick Jump to Start/End Points** — Added `Shift + J` (jump to the clip's Start Cut point) and `Shift + L` (jump to the clip's End Cut point), each with a corresponding on-screen button placed next to their respective 5-second seek controls.
- **Centered Start/End Duration Display** — Moved the Start and End cut point duration labels to the absolute center of their UI area.
- **"Set End" Bracket Color** — Changed the "Set End" (`]`) control's color to red.

### Keyboard Shortcuts & Navigation

**Major:**
- **Playback Speed Shortcuts** — Adjustable via `Shift + ,` (`<`) and `Shift + .` (`>`). Stepping is absolute (non-cyclic) and stops at the minimum/maximum speed.

**Minor:**
- **Renamed Percentage-Jump Shortcuts** — The playhead jump shortcuts for 25% / 50% / 75% changed from `1 / 2 / 3` to `I / O / P`.
- **Jump to Beginning/End Shortcuts** — `Shift + I` jumps the playhead to the beginning of the video, and `Shift + P` jumps to the end.
- **Volume Adjustment Shortcut** — `Shift + Arrow Up` / `Shift + Arrow Down` raises/lowers the volume, where supported.
- **Mute Toggle Shortcut** — Added `M` as a shortcut to toggle mute/unmute.
- **Quick Jump to Start/End Trim Shortcuts** — `Shift + J` jumps the playhead to the clip's Start Cut point; `Shift + L` does the same for the End Cut point.
- **Delete Shortcut & Popup Controls** — Pressing `Del` opens the delete confirmation dialog for the selected clip; inside the dialog, `Enter` confirms the deletion and `Esc` cancels it.
- **Rename Flow (`F2`)** — Mapped `F2` to rename the file, automatically focusing the text field so the user can type immediately without a mouse click. Pressing `Enter` saves the new name and safely returns keyboard focus to the main interface, ensuring it doesn't conflict with the `Enter` shortcut used for trimming.

---

## [1.0.0] - 2026-07-06
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
