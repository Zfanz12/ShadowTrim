# Changelog
All notable changes to ShadowTrim will be documented in this file.

## Upcoming Fixes & Features

_No items currently planned — all previously listed items have shipped in [2.0.0]._

# Releases

## [2.0.0] - 2026-07-12

### Bug Fixes & Performance Enhancements

**Major :**
- **Fix Duplicate Trimmed Revision Bug** — Fixed a bug causing duplicate entries to be created when a trimmed clip is revised.
- **Fix Missing Session-Exit Save Prompt** — Fixed a bug where the "Save Session" popup sometimes failed to appear when exiting the app.
- **Fix Missing Trim Markers After Session Reload** — Fixed a bug where, after closing and reloading a previous session, clips in the Trimmed group that were in a "trimmed but not yet revised" state didn't show their seek bar and trim markers in the preview.
- **Fix Arrow-Key Navigation Inconsistency** — Fixed a bug where navigating the clip list with Arrow Up/Down didn't move through clips consistently.
- **Fix Rename Duplicating Trimmed File** — Fixed a bug where renaming a clip that's already in the Trimmed group created a duplicate file in the output folder instead of renaming/replacing the existing trimmed file.

**Minor :**
- **Resolve List Scrolling Lag** — Fixed a performance issue where scrolling down the video list accidentally loaded all videos simultaneously, causing the application to lag. Implemented lazy loading and optimized rendering.
- **Duplicate Filename Handling** — Implemented a safeguard for duplicate file names. If a name already exists, the app prompts a rename popup or automatically appends a sequence number (e.g., "filename (2)").

### New Features & Core Logic

**Major :**
- **Recycle Bin Integration & Delete Flow Rework** — Deleted files are now moved to the system Recycle Bin instead of being permanently deleted. Clicking "Delete Clip" no longer deletes immediately — it flags the clip for deletion, and the actual move to Recycle Bin only executes when the user selects "End This Session."
- **"Deleted" Group in Sidebar** — Added a new "Deleted" group in the left sidebar, placed below "Untrimmed." Works the same way as other groups; clips flagged for deletion appear here until the session ends and the deletion is executed.
- **Revise Trimmed Clip** — Added the ability to revise/re-trim a clip that has already been trimmed, instead of only being able to trim it once.
- **"Delete Original Clip" Checkbox** — Added an optional checkbox in the export panel to delete the source file after a successful trim. Unchecked by default, and highlighted in red when checked as a visual warning.

**Minor :**
- **Rename Reflects in Trimmed Output** — When a clip's filename is changed, the new name is now correctly shown on the trimmed version, instead of still displaying the original filename.
- **Flag Icon for "Delete Original Clip"** — Added an icon on clips in the Trimmed group that are flagged to have their original file deleted, so it's clear at a glance which clips are marked.

### Session Management System

**Major :**
- **Session Memory Management** — A blacklist file tracks previously trimmed video names so they don't reappear in the active list, even if "Delete file after trim" is unchecked. If the user chooses "Save" on the exit prompt, the blacklist is written; if the user chooses "Delete this session," the blacklist is not saved.
- **Session Save Prompt on Exit** — Added a confirmation dialog when closing the app with an active session, offering three options: "Save," "Delete this session," and "Cancel."
- **Resume Session After Restart** — Users can now close the app and continue a previous session later without losing their progress.

**Minor :**
- **"End This Session" Button** — Added a button to manually end/wrap up the current session (e.g., once tidying up clips is done), which also triggers execution of any pending flagged deletions.

### Quality of Life (QoL) & UI/UX Improvements

**Major :**
- **Playback Speed Control** — Added a speed selector (1x, 1.5x, 2x, 3x) placed next to the volume control.

**Minor :**
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

**Major :**
- **Playback Speed Shortcuts** — Adjustable via `Shift + ,` (`<`) and `Shift + .` (`>`). Stepping is absolute (non-cyclic) and stops at the minimum/maximum speed.

**Minor :**
- **Renamed Percentage-Jump Shortcuts** — The playhead jump shortcuts for 25% / 50% / 75% changed from `1 / 2 / 3` to `I / O / P`.
- **Jump to Beginning/End Shortcuts** — `Shift + I` jumps the playhead to the beginning of the video, and `Shift + P` jumps to the end.
- **Volume Adjustment Shortcut** — `Shift + Arrow Up` / `Shift + Arrow Down` raises/lowers the volume, where supported.
- **Mute Toggle Shortcut** — Added `M` as a shortcut to toggle mute/unmute.
- **Quick Jump to Start/End Trim Shortcuts** — `Shift + J` jumps the playhead to the clip's Start Cut point; `Shift + L` does the same for the End Cut point.
- **Delete Shortcut & Popup Controls** — Pressing `Del` opens the delete confirmation dialog for the selected clip; inside the dialog, `Enter` confirms the deletion and `Esc` cancels it.
- **Rename Flow (`F2`)** — Mapped `F2` to rename the file, automatically focusing the text field so the user can type immediately without a mouse click. Pressing `Enter` saves the new name and safely returns keyboard focus to the main interface, ensuring it doesn't conflict with the `Enter` shortcut used for trimming.

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
