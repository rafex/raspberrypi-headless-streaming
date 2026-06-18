# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.3.0] - 2026-06-17

### Added

- **Web API: acordeón de 5 pasos con paridad total al TUI**
  - Interfaz reorganizada como asistente de configuración colapsable
  - Paso 1 — Cámara: grid 2×2 de resoluciones (360p/480p/720p/1080p) con
    descripción, sección Personalizado colapsable
  - Paso 2 — Audio: sample rate, toggle stereo/mono, boost ×2, hint
    automático para BOYA/Focusrite/Scarlett → 48 000 Hz
  - Paso 3 — Destino: YouTube, Facebook, Dual (★) y URL personalizada;
    segundo campo de stream key para modo dual
  - Paso 4 — Video: cards 2×2 de calidad nombradas (Alta calidad / Balance /
    Bajo ancho / Mínimo); sección Avanzado con bitrate y preset libres
  - Paso 5 — Overlays: chips de ancho de logo (Original/80/100/120/150/200 px),
    chips de margen (10–50 px), grids visuales de posición (2×2 logo, 3×3
    texto), toggle de banner con posición footer/header
  - Chips de resumen en tiempo real en cada cabecera del acordeón

- **Banner overlay (Overlay 5)**
  - Nuevo flag `--banner TEXT` y `--banner-pos footer|header` en
    `stream-overlay.sh`
  - Implementado con `drawbox` (46 px, `black@0.72`) + `drawtext` centrado
    (`x=(w-text_w)/2`)
  - Escapa automáticamente `:` → `\:` y `'` → `\'` en el texto del banner
  - Variables de entorno: `OVERLAY_BANNER`, `OVERLAY_BANNER_POS`

- **Audio boost ×2**
  - Nuevo flag `--audio-boost` en `stream-overlay.sh`
  - Aplica `-af "aresample=async=1:min_hard_comp=0.100000:first_pts=0,volume=2.0"`
  - Útil para micrófonos de solapa con nivel bajo (ej. BOYA CC)
  - Variable de entorno: `STREAM_AUDIO_BOOST`

- **Ancho de logo configurable**
  - Nuevo flag `--logo-w N` (N=0 → original)
  - Variable de entorno: `OVERLAY_LOGO_W`

- **Dual stream via web API**
  - La opción "★ Dual" en la web compose y envía ambas URLs RTMP al script
  - Variables nuevas: `STREAM_PLATFORM`, `STREAM_KEY`, `STREAM_DUAL`,
    `STREAM_KEY_META`, `RTMP_URL_SECONDARY`

- **Auto-detección de sample rate**
  - Nombres de micrófono con BOYA, Focusrite o Scarlett auto-seleccionan
    48 000 Hz en la UI web y en el TUI

### Fixed

- `streaming-overlay.service`: eliminado `--no-audio` hardcodeado de
  `ExecStart`; el silencio AAC ahora se controla exclusivamente mediante
  `STREAM_NO_AUDIO` en `/etc/streaming.env`
- Escaping del texto del banner: corregido número de backslashes en `sed`
  para producir exactamente `\'` en los filtros ffmpeg

---

## [0.2.0] - 2026-04-25

### Added

- **Dual-Stream Broadcasting**
  - Simultaneous streaming to YouTube and Facebook (experimental)
  - FFmpeg tee muxer: video encoded once, sent to multiple platforms
  - Independent failure handling: if one platform fails, other continues
  - Interactive TUI option: "★ Dual stream — YouTube + Facebook"

- **Interactive Overlays (Complete System)**
  - PNG logo support with URL download (HTTP/HTTPS)
  - Auto-detection of transparent vs opaque images
  - Logo positioning: top-left, top-right, bottom-left, bottom-right
  - Configurable logo size and padding from edges
  - Banner text with dark background (header or footer)
  - Font auto-detection: Liberation/FreeFont/Noto Sans Bold
  - Advanced FFmpeg filter_complex for logo + banner combinations

### Fixed

- **Banner Text Robustness**
  - Replace manual character escaping with textfile approach
  - Handles special characters (colons, quotes, etc.) without quoting issues
  - More reliable for user-supplied text

### Improved

- **Logo Processing Performance**
  - Pre-resize logos offline (before stream starts) instead of real-time
  - Reduces CPU load during transmission on resource-constrained hardware
  - Uses ffmpeg -vf scale (primary) or ImageMagick convert (fallback)
  - Significant efficiency gain for 1080p+ overlays on Pi 3B

- **Stream TUI Usability**
  - Simplified filter expressions and mapping logic
  - Better organization of filter components
  - Extended workflow from 4 steps to 5 (overlays now dedicated step)
  - Smarter integration between overlays, dual-stream, and audio

---

## [0.1.0] - 2026-04-25

### Added

- **Core Capture Scripts**
  - `capture.sh`: Capture video from CSI Camera Module with optional audio
  - `rec.sh`: Quick record script for USB cameras with auto-detection
  - `usb-camera.sh`: Dedicated USB camera capture/stream script with v4l2 support

- **Streaming & Broadcasting**
  - `stream.sh`: RTMP streaming to YouTube, Facebook, and custom RTMP servers
  - `stream-overlay.sh`: Streaming with logo/frame overlays and text rendering
  - `stream-rtsp.sh`: RTSP server mode with mediamtx integration
  - `stream-tui.sh`: Interactive terminal UI for configuring stream parameters

- **Recording & Archiving**
  - `record.sh`: Basic video recording with optional audio
  - `stream-record.sh`: Simultaneous streaming and local recording

- **Overlay & Effects**
  - `generate-assets.sh`: Generate example PNG logos and frames
  - Overlay support: logos, frames, dynamic text, timestamps via ffmpeg

- **Audio Processing**
  - `audio-check.sh`: USB microphone detection and configuration
  - Multi-channel support: mono/stereo audio capture
  - Microphone volume control (--mic-vol flag)
  - ALSA device management and level monitoring

- **Device Detection & Setup**
  - `check-devices.sh`: Detect connected cameras and audio devices
  - `install-deps.sh`: Automated dependency installation with profiles
  - Support for Raspberry Pi OS and DietPi
  - Camera Module (CSI) and USB camera detection

- **Automation & Control**
  - `control.sh`: Systemd service management (start/stop/status/logs)
  - `motion-detect.sh`: Motion detection with ffmpeg frame analysis
  - `motion-trigger.sh`: Event-triggered streaming on motion detection

- **Advanced Features**
  - Motion-based event streaming
  - RTSP server support via mediamtx
  - Systemd service templates for auto-start on boot
  - Environment variable configuration support

- **AI Integration**
  - `ai-server-install.sh`: Install AI inference server
  - `ai-pipeline.sh`: Video analysis with DeepSeek/OpenRouter
  - Standalone AI analysis server with REST API
  - Frame extraction and LLM analysis pipeline

- **Documentation**
  - `README.md`: Quick start and feature overview
  - `docs/install.md`: Step-by-step installation guide
  - `docs/setup.md`: Configuration and systemd automation
  - `docs/audio.md`: USB microphone and ALSA configuration
  - `docs/overlays.md`: Overlay and text rendering guide
  - `docs/architecture.md`: Pipeline diagrams and system design
  - `docs/ai-integration.md`: AI analysis and webhook integration

### Fixed

- ALSA device name extraction robustness (grep -oP → grep -oE)
- Audio-video synchronization with ffmpeg thread queues and async resampling
- Path logic for recording output (default to /tmp)
- FFmpeg compatibility with versions 7.0+ (-fps_mode vs -vsync)
- USB microphone sample rate auto-detection
- Device parsing with multiple ALSA interfaces

### Improved

- `pick()` function refactoring: now returns array index for cleaner logic
- Audio buffer tuning for stable USB microphone capture
- Device label formatting in TUI (simplified color codes)
- Error handling in device detection scripts
- Help documentation and usage examples
- Shell script portability and POSIX compliance

### Infrastructure

- Comprehensive systemd service templates
- Environment file patterns for credential management
- CI/CD ready structure (GitHub Actions compatible)
- Multi-profile dependency installation

---

## Project Overview

**raspi-headless-streaming** v0.1.0 demonstrates how to build a lightweight, headless video capture and live streaming system for Raspberry Pi 3B/4 using CLI tools only.

### Key Technologies

- **Capture**: libcamera (CSI), v4l2 (USB cameras)
- **Encoding**: H.264 via hardware/libx264
- **Streaming**: RTMP (FFmpeg), RTSP (mediamtx)
- **Audio**: ALSA, USB microphones
- **Analysis**: FFmpeg, AI models (DeepSeek, OpenRouter)
- **Automation**: Bash, systemd

### Supported Platforms

- **Primary**: Raspberry Pi 3B+, 4 (32/64-bit)
- **OS**: Raspberry Pi OS, DietPi Lite
- **Camera**: CSI Module v1/v2/v3, USB UVC
- **Microphone**: USB, BOYALINK CC, Focusrite Scarlett

### Design Philosophy

- ✅ CLI-first: All operations via command line
- ✅ Minimal dependencies: Prefer tools in Debian repos
- ✅ Headless: No GUI, no desktop environment required
- ✅ Automation-friendly: Scriptable, suitable for edge deployments
- ✅ Open source: FFmpeg, libcamera, bash

---

## Known Limitations (v0.1.0)

- CPU intensive overlays on Pi 3B (limit to 1 overlay)
- Audio sync may drift on very long recordings (>2 hours)
- AI inference requires external API or local processing
- Motion detection tuning requires per-environment calibration

## Future Roadmap

- Multi-camera support
- Hardware-accelerated overlay rendering
- Local AI models (ONNX edge optimization)
- REST control API layer
- Web dashboard for monitoring
- Kubernetes deployment templates

---

[0.3.0]: https://github.com/rafex/raspberrypi-headless-streaming/releases/tag/v0.3.0
[0.2.0]: https://github.com/rafex/raspberrypi-headless-streaming/releases/tag/v0.2.0
[0.1.0]: https://github.com/rafex/raspberrypi-headless-streaming/releases/tag/v0.1.0
