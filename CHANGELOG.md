# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/rafex/raspberrypi-headless-streaming/releases/tag/v0.1.0
