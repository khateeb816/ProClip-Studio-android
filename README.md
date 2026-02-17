# ProClip Studio - App Overview

## 1. Introduction
**ProClip Studio** is a high-performance video editing and clipping application built with Flutter. It is designed to take long-form video content and rapidly turn it into short, viral-style clips (e.g., for TikTok, Reels, Shorts) with optimized hardware-accelerated export pipelines.

## 2. Project Structure

The project follows a standard Flutter feature-first architecture:

```
lib/
├── main.dart                 # Application Entry Point & Initialization
├── models/                   # Data Models
│   ├── video_metadata.dart   # Video properties (res, fps, bitrate)
│   └── video_settings.dart   # Per-video edit state (crop, trim, audio)
├── screens/                  # UI Screens
│   ├── editor_screen.dart    # Core video editing interface
│   ├── export_screen.dart    # Export progress and configuration
│   ├── media_picker_screen.dart # File selection
│   └── ...
├── services/                 # Core Business Logic & Singletons
    ├── ffmpeg_service.dart   # Video processing engine (FFmpeg Kit)
    ├── titanium_service.dart # Native Engine Bridge (Method Channels)
    └── notification_service.dart # Local notifications
```

## 3. Key Features & Workflows

### 3.1. Video Engine Options
The app uses two processing engines:
1.  **FFmpeg Engine (Primary):** Handles most tasks using `ffmpeg_kit_flutter`.
2.  **Titanium Engine:** A native engine bridge (`com.clipper.titanium/engine`) for potentially higher performance or specialized rendering tasks.

### 3.2. Smart Export Pipeline (`FFmpegService`)
The export logic is highly optimized for speed ("Zero Copy" philosophy). It attempts to find the fastest path to render the video:
1.  **Stream Copy (Fastest):** If no changes (crop, audio, scale) are made, it copies the video stream bit-for-bit.
2.  **Hardware Acceleration:** If re-encoding is needed (e.g., cropping), it forces **Android MediaCodec** or **iOS VideoToolbox** hardware encoders.
3.  **Software Fallback:** If hardware encoding fails, it falls back to `libx264` with `semifast/ultrafast` presets.

### 3.3. Editor Capabilities (`EditorScreen`)
-   **Multi-Video Workflow:** Load multiple videos and switch between them instantly.
-   **Precision Cropping:** Uses an interactive viewer (pan/zoom) to define crop regions. The app calculates precise normalized crop rectangles.
-   **Proxy Handling:** Uses specific logic to detect HEVC/H.265 videos or playback failures and switch to proxy files for smoother editing.
-   **Audio Management:**
    -   Mix external audio files (mp3, wav).
    -   Extract audio from other video files.

### 3.4. Automatic Clipping
The app can automatically split a long video into multiple segments (e.g., 30-second clips) in a batch process, handling the math to prevent gaps or overlaps.

## 4. Architecture & State Management

-   **State Management:** Currently relies on local state (`setState`) within `EditorScreen` and passing data models (`VideoSettings`) between screens.
-   **Data Models:**
    -   `VideoSettings`: Holds the "Edit Decision List" for a specific video file (crop rect, zoom level, assigned audio, generic metadata).
    -   `VideoMetadata`: Technical specs of the video file (codec, bitrate, fps).
-   **Services:** Implemented as static singletons to be accessible globally (e.g., `FFMpegService.executeSmartExport`).

## 5. Critical Files Guide

| File | Purpose |
|------|---------|
| `lib/services/ffmpeg_service.dart` | **The Brain.** Contains the logic for constructing FFmpeg commands, handling hardware acceleration flags, and managing the export queue. |
| `lib/screens/editor_screen.dart` | **The Interface.** Handles the complex gesture logic for cropping, video player controller caching, and state tracking. |
| `lib/main.dart` | **The Bootloader.** Initializes async services (`Titanium`, `FFmpegConfig`) before mounting the UI to ensure the engine is ready. |

## 6. How it Works (Under the Hood)

1.  **Initialization:** App starts -> Inits Notification & FFmpeg configs -> Checks for Native Engine.
2.  **Loading:** User picks files -> App creates `VideoSettings` for each -> Lazy loads metadata and initializes the first video player.
3.  **Editing:**
    -   User pans/zooms -> `TransformationController` updates.
    -   On Export, `_getPreciseCropRect()` translates the visual zoom into a normalized (0.0-1.0) rectangle for FFmpeg `crop` filter.
4.  **Export:**
    -   `ExportScreen` receives the settings.
    -   It calls `FFMpegService.executeSmartExport`.
    -   Service constructs a command chain: `Seek -> Audio Mix -> Scale -> Crop -> Encode -> Mux`.
    -   Output is saved to Gallery using `gal` package.

# ProClip-Studio-android
