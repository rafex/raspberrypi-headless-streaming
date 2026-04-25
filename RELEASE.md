# Release v0.1.0

**Date**: 2026-04-25  
**Version**: 0.1.0 (Initial Release)  
**Status**: Stable  

---

## Summary

**raspi-headless-streaming v0.1.0** is the initial production-ready release of a lightweight, headless video capture and live streaming system designed for Raspberry Pi devices.

This version includes everything needed to:
- Capture video from CSI or USB cameras
- Live stream to YouTube, Facebook, or custom RTMP servers
- Apply real-time overlays (logos, text, timestamps)
- Record locally while streaming
- Detect motion and trigger events
- Integrate AI-powered video analysis
- Automate streaming workflows with systemd

---

## Key Features

### 📹 Video Capture
- **CSI Camera Module**: Direct support for Raspberry Pi Camera v1/v2/v3
- **USB Cameras**: Standard USB UVC webcams with auto-detection
- **Hardware Acceleration**: H.264 encoding via native Pi hardware
- **Flexible Formats**: Configurable resolution, framerate, bitrate

### 📡 Streaming
- **Multi-platform**: YouTube Live, Facebook Live, custom RTMP
- **Interactive Config**: TUI for easy stream parameter selection
- **Simultaneous Recording**: Stream + local archive in one pipeline
- **RTSP Server Mode**: Broadcast as RTSP stream via mediamtx

### 🎨 Overlays & Effects
- **Dynamic Logos**: Transparent PNG logos with positioning
- **Text Rendering**: Timestamps, custom text via drawtext filter
- **Frame Graphics**: PNG frames/borders with overlay blending
- **Real-time Processing**: Low-latency overlay rendering

### 🎙️ Audio Capture
- **USB Microphones**: Full ALSA support with auto-detection
- **Multi-channel**: Mono/stereo capture configuration
- **Volume Control**: Adjustable microphone gain (--mic-vol flag)
- **Sample Rate Detection**: Auto or manual audio sample rate
- **Known Devices**: BOYA, Focusrite Scarlett with specific fixes

### 🤖 AI Integration
- **Frame Analysis**: Extract frames and send to DeepSeek/OpenRouter
- **REST API**: Webhook notifications on analysis results
- **Event Triggers**: Motion detection + AI classification workflows
- **Modular Design**: External AI server for flexibility

### ⚙️ Automation
- **Systemd Services**: Auto-start streaming on boot
- **Motion Triggers**: Start/stop streaming based on motion
- **Event Webhooks**: Integrate with external systems
- **Environment Config**: Secure credential management

### 🛠️ Setup & Configuration
- **One-command Install**: `install-deps.sh` with profiles
- **Device Detection**: Auto-discover cameras and microphones
- **Multi-OS Support**: Raspberry Pi OS, DietPi Lite
- **Setup Guide**: Comprehensive step-by-step documentation

---

## Installation

### Quick Start (5 minutes)

```bash
# Install dependencies
sudo scripts/install-deps.sh --usb-camera

# Test camera
scripts/capture.sh -t 5

# Stream to YouTube
scripts/stream.sh -u rtmp://a.rtmp.youtube.com/live2/YOUR_STREAM_KEY
```

### Full Documentation

See [docs/install.md](docs/install.md) for complete setup instructions including:
- Raspberry Pi OS vs DietPi configuration
- CSI Camera Module activation
- USB microphone ALSA setup
- Focusrite Scarlett driver fixes
- Systemd service automation

---

## Usage Examples

### Capture Video Only
```bash
scripts/capture.sh -t 30 -o recording.h264
```

### Record with Audio
```bash
scripts/rec.sh --mic-vol 2.0 -t 60 demo.mp4
```

### Stream with Overlay
```bash
scripts/stream-overlay.sh \
    -u rtmp://a.rtmp.youtube.com/live2/KEY \
    --logo assets/logo.png \
    --timestamp
```

### Interactive Stream Setup
```bash
scripts/stream-tui.sh
```
*(Select camera, microphone, resolution, platform interactively)*

### Motion-Triggered Streaming
```bash
scripts/motion-trigger.sh \
    -u rtmp://server/live/key \
    --start-delay 5 \
    --stop-delay 10
```

### Check Devices
```bash
scripts/check-devices.sh
# Lists all USB cameras and audio devices with specs
```

---

## Performance Targets (Pi 3B)

| Setting | Recommended | Max |
|---------|-------------|-----|
| Resolution | 1080p | 1080p |
| Framerate | 30 FPS | 30 FPS |
| Bitrate | 4–5 Mbps | 6 Mbps |
| Overlays | 1 simple | 2 lightweight |
| Audio | USB Mono | Stereo |
| Duration | Unlimited | 2+ hours tested |

---

## Hardware Tested

### Raspberry Pi
- ✅ Raspberry Pi 3B+
- ✅ Raspberry Pi 4 (2GB+)

### Cameras
- ✅ CSI Camera Module v2
- ✅ USB Webcam (Logitech C920, etc.)

### Microphones
- ✅ BOYA BY-U37
- ✅ Focusrite Scarlett Solo (with driver fix)
- ✅ Generic USB audio capture

### Operating Systems
- ✅ Raspberry Pi OS Lite (32-bit, 64-bit)
- ✅ DietPi Lite

---

## Files Included

### Scripts (`scripts/`)
| File | Purpose |
|------|---------|
| `capture.sh` | CSI camera capture |
| `usb-camera.sh` | USB camera capture |
| `rec.sh` | Quick record (USB camera + audio) |
| `stream.sh` | Basic RTMP streaming |
| `stream-overlay.sh` | Streaming with overlays |
| `stream-tui.sh` | Interactive streaming config |
| `record.sh` | Recording pipeline |
| `audio-check.sh` | USB audio device detection |
| `check-devices.sh` | Camera and audio device info |
| `install-deps.sh` | Automated dependency install |
| `control.sh` | Systemd service control |
| `motion-detect.sh` | Motion detection |
| `motion-trigger.sh` | Event-based streaming |
| `ai-pipeline.sh` | Frame analysis with LLM |
| `generate-assets.sh` | Generate example overlays |

### Documentation (`docs/`)
| File | Content |
|------|---------|
| `install.md` | Step-by-step setup guide |
| `setup.md` | Configuration & systemd |
| `audio.md` | USB microphone setup |
| `overlays.md` | Overlay & text effects |
| `architecture.md` | System design & diagrams |
| `ai-integration.md` | AI server & webhooks |

### Systemd Templates (`systemd/`)
| File | Service |
|------|---------|
| `streaming.service` | Basic streaming service |
| `streaming-overlay.service` | Streaming with overlays |
| `motion-trigger.service` | Motion-triggered streaming |
| `ai-server.service` | AI analysis server |
| `mediamtx.service` | RTSP server |

---

## Breaking Changes

None. This is the initial release.

---

## Known Issues

### v0.1.0

1. **Audio Sync Drift**: Long recordings (>2 hours) may experience slight A/V drift
   - *Workaround*: Use shorter segments or reduce bitrate

2. **Overlay CPU Load**: Multiple overlays on Pi 3B cause framerate drops
   - *Workaround*: Limit to 1–2 lightweight overlays or upgrade to Pi 4

3. **Motion Detection Tuning**: Sensitivity varies per environment
   - *Workaround*: Adjust threshold in `motion-detect.sh` for your lighting

4. **Focusrite Scarlett**: Requires driver fix on Pi 3B
   - *Workaround*: Run `scripts/scarlett-pi3b-fix.sh` (included)

---

## Upgrade Path

For users updating from development versions:
- ✅ All scripts backward compatible
- ✅ No config file breaking changes
- ✅ Existing systemd services continue to work
- ⚠️ FFmpeg version 7.0+: Use `-fps_mode` instead of `-vsync`

---

## Support & Community

- **Issues**: [GitHub Issues](https://github.com/rafex/raspberrypi-headless-streaming/issues)
- **Discussions**: [GitHub Discussions](https://github.com/rafex/raspberrypi-headless-streaming/discussions)
- **Documentation**: See `README.md` and `docs/` folder

---

## License

[LICENSE](LICENSE) — GPL-3.0 equivalent

---

## Credits

- **FFmpeg**: Video encoding and processing
- **libcamera**: Raspberry Pi camera support
- **mediamtx**: RTSP server
- **ALSA**: Audio capture and management
- **systemd**: Process management

---

## Next Steps

1. **Try it out**: Follow [docs/install.md](docs/install.md)
2. **Test hardware**: Run `scripts/check-devices.sh`
3. **Explore examples**: See usage examples above
4. **Report issues**: [GitHub Issues](https://github.com/rafex/raspberrypi-headless-streaming/issues)
5. **Contribute**: PRs welcome for features and fixes

---

**Happy streaming! 🚀**
