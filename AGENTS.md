# AGENTS.md

## Project
raspi-headless-streaming

Headless video capture and live streaming system designed for Raspberry Pi devices using command line tools only.  
The project demonstrates how to build a lightweight broadcasting pipeline using hardware acceleration and open source software.

The system captures video from a camera, optionally applies overlays (logos, frames, text), and streams to platforms such as YouTube or Facebook using RTMP.

This project intentionally avoids graphical environments and tools such as OBS.

---

# Goals

This repository demonstrates that:

- Raspberry Pi can be used as a headless broadcasting node
- Streaming workflows can run entirely from CLI
- Open source tools can replace GUI broadcast software
- Low-power edge devices can perform capture → processing → streaming

Primary objectives:

1. Capture video from a camera attached to Raspberry Pi
2. Encode using H264
3. Optionally apply overlays (logo, frame, text)
4. Stream to a remote platform via RTMP
5. Keep the system lightweight and automation-friendly

---

# Design Principles

### CLI First
All operations must be executable from command line.

No GUI tools are used.

### Minimal Dependencies
Prefer simple tools available in Debian/DietPi repositories.

Primary tools:

- libcamera
- ffmpeg
- bash
- systemd

### Headless Operation
The system must run without:

- desktop environment
- graphical libraries
- manual interaction

### Automation Friendly
All functionality must be scriptable and usable in automation.

---

# Target Hardware

Primary target:

Raspberry Pi 3B or Raspberry Pi 4.

Constraints:

- limited CPU
- limited RAM
- preference for hardware encoding

---

# Core Components

## Camera Capture

Video capture is performed using:

libcamera-vid

Example:

bash libcamera-vid -t 0 \   --width 1920 \   --height 1080 \   --framerate 30 \   --codec h264 \   -o - 

This outputs H264 video to stdout.

---

## Video Processing

Video processing and streaming is performed using:

ffmpeg

Responsibilities:

- overlay logos
- add frames
- render text
- package video for RTMP streaming

Example:

bash ffmpeg -re -i - \   -i logo.png \   -filter_complex "overlay=10:10" \   -vcodec libx264 \   -f flv rtmp://server/live/key 

---

## Streaming

Streaming is performed via RTMP.

Supported platforms include:

- YouTube Live
- Facebook Live
- RTMP servers

Example endpoint:

rtmp://a.rtmp.youtube.com/live2/<STREAM_KEY>

---

# Overlay System

Overlays are applied using ffmpeg filters.

Supported overlays:

- PNG logos
- PNG frames
- dynamic text
- timestamps

Example overlay:

overlay=W-w-20:H-h-20

Example text overlay:

drawtext=text='Raspi Streaming Demo'

---

# Repository Structure

Recommended structure:

raspi-headless-streaming/  scripts/     stream.sh     stream-overlay.sh     record.sh  assets/     logo.png     frame.png  systemd/     streaming.service  docs/     setup.md     architecture.md

---

# Example Streaming Pipeline

The typical pipeline:

camera  
↓  
hardware encoder  
↓  
ffmpeg overlays  
↓  
RTMP streaming  

Example command:

bash libcamera-vid -t 0 \   --width 1920 \   --height 1080 \   --framerate 30 \   --codec h264 \   -o - | \ ffmpeg -re -i - \   -i assets/logo.png \   -filter_complex "overlay=W-w-20:H-h-20" \   -vcodec libx264 \   -preset veryfast \   -b:v 4500k \   -f flv rtmp://a.rtmp.youtube.com/live2/STREAM_KEY 

---

# Automation

Streaming can be automated using systemd.

Example service:

/etc/systemd/system/stream.service

Responsibilities:

- start stream automatically
- restart on failure
- run without user interaction

---

# Performance Constraints

On Raspberry Pi 3B:

Recommended configuration:

- 1080p
- 30 FPS
- bitrate ~4–5 Mbps

Avoid heavy filters.

Overlays require re-encoding and increase CPU usage.

---

# Future Extensions

Potential improvements:

- RTSP server mode
- motion detection
- event-based streaming
- AI analysis integration
- multi-camera support
- REST control API

---

# Non-Goals

This project will NOT include:

- graphical interfaces
- OBS integration
- desktop dependencies
- heavy frameworks

---

# Philosophy

This project demonstrates that:

broadcast systems do not require GUI software.

With simple Unix tools it is possible to build reliable video pipelines suitable for:

- edge devices
- automation
- embedded deployments
- security research
- live demos