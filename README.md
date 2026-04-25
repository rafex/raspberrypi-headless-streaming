# raspberrypi-headless-streaming

Headless Raspberry Pi streaming setup using CLI tools. Capture video, apply overlays (logos, frames, text), and broadcast live to platforms like YouTube or Facebook using FFmpeg and libcamera. Designed for lightweight edge devices without GUI, ideal for automation, demos, and embedded broadcasting systems.

## Inicio rápido

```bash
sudo apt install -y libcamera-apps ffmpeg alsa-utils git
git clone https://github.com/rafex/raspberrypi-headless-streaming.git
cd raspberrypi-headless-streaming
chmod +x scripts/*.sh
scripts/capture.sh -t 5                                      # probar cámara
scripts/stream.sh -u rtmp://TU_PLATAFORMA/TU_KEY            # hacer streaming
```

Ver la guía completa de instalación: [docs/install.md](docs/install.md)

## Documentación

| Documento | Descripción |
|---|---|
| [docs/install.md](docs/install.md) | Instalación paso a paso en Pi 3B |
| [docs/setup.md](docs/setup.md) | Configuración inicial y systemd |
| [docs/audio.md](docs/audio.md) | Audio USB, BOYALINK CC, Focusrite Scarlett |
| [docs/overlays.md](docs/overlays.md) | Logos, marcos, timestamps con ffmpeg |
| [docs/architecture.md](docs/architecture.md) | Diagramas del pipeline de video |
| [docs/ai-integration.md](docs/ai-integration.md) | Análisis de video con DeepSeek / OpenRouter |
