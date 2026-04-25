# Instalación en Raspberry Pi 3B

Guía paso a paso para instalar y poner en marcha el sistema de streaming headless desde cero.

---

## ¿Qué tipo de cámara usas?

El primer paso es identificar tu cámara, ya que el proceso y los scripts difieren:

| Tipo | Conexión | Configuración | Script |
|---|---|---|---|
| **Cámara USB** (webcam, UVC) | Puerto USB-A | Plug & play — sin configuración | `scripts/usb-camera.sh` |
| **Módulo CSI oficial** (Camera Module v1/v2/v3) | Cable flat al puerto CSI | Requiere activar en `raspi-config` | `scripts/capture.sh` / `scripts/stream.sh` |

> **Si usas cámara USB:** no necesitas `raspi-config`, no necesitas `libcamera-apps` y no necesitas reiniciar. El kernel la detecta automáticamente como `/dev/video0`.

---

## Requisitos previos

| Componente | Mínimo |
|---|---|
| Placa | Raspberry Pi 3B / 3B+ |
| OS | Raspberry Pi OS Lite (64-bit recomendado) o DietPi |
| Cámara | Cámara USB UVC **o** Camera Module v1/v2/v3 |
| microSD | 8 GB clase 10 o superior |
| Red | Ethernet (recomendado) o Wi-Fi |
| Acceso | SSH o teclado/monitor |

---

## Paso 1 — Actualizar el sistema

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Paso 2 — Instalar dependencias

### Cámara USB (recomendado para empezar)

```bash
sudo apt install -y \
    ffmpeg \
    v4l-utils \
    alsa-utils \
    git \
    curl
```

### Módulo CSI (Camera Module oficial)

```bash
sudo apt install -y \
    libcamera-apps \
    ffmpeg \
    alsa-utils \
    git \
    curl
```

| Paquete | Para qué se usa |
|---|---|
| `ffmpeg` | encoding, overlays, streaming RTMP, audio |
| `v4l-utils` | detectar y configurar cámaras USB (`v4l2-ctl`) |
| `alsa-utils` | detección y prueba de micrófono USB (`arecord`, `alsamixer`) |
| `libcamera-apps` | solo si usas el módulo CSI oficial (`libcamera-vid`) |
| `git` | clonar el repositorio |
| `curl` | descargar mediamtx (opcional) |

---

## Paso 3 — Configurar la cámara

### Opción A: Cámara USB — sin configuración

Conectar la cámara al puerto USB y verificar que el kernel la detectó:

```bash
# Listar dispositivos de video
ls /dev/video*
# Debe aparecer al menos /dev/video0

# Ver información de la cámara y formatos soportados
v4l2-ctl --device=/dev/video0 --info
v4l2-ctl --device=/dev/video0 --list-formats-ext
```

No se necesita `raspi-config`, no se necesita reiniciar.

### Opción B: Módulo CSI — requiere activación

**En Raspberry Pi OS:**

```bash
sudo raspi-config
# Interface Options → Camera → Enable
sudo reboot
```

**En DietPi:**

```bash
sudo dietpi-config
# Advanced Options → Camera → Enable
sudo reboot
```

Verificar tras reiniciar:

```bash
libcamera-hello --list-cameras
```

---

## Paso 4 — Clonar el repositorio

```bash
git clone https://github.com/rafex/raspberrypi-headless-streaming.git
cd raspberrypi-headless-streaming
chmod +x scripts/*.sh
```

---

## Paso 5 — Verificar la cámara

### Cámara USB

```bash
# Ver cámaras USB detectadas y sus resoluciones
scripts/usb-camera.sh --list

# Grabar 5 segundos de prueba
scripts/usb-camera.sh --capture -t 5 -o /tmp/test.mp4

# Ver el tamaño del archivo
ls -lh /tmp/test.mp4
```

### Módulo CSI

```bash
# Grabar 5 segundos de prueba
scripts/capture.sh -t 5 -o /tmp/test.h264

ls -lh /tmp/test.h264
```

---

## Paso 6 — Micrófono USB (opcional)

Si vas a capturar audio con micrófono USB, BOYALINK CC o Focusrite Scarlett:

### 6a. Conectar el micrófono y detectarlo

```bash
scripts/audio-check.sh
```

El script lista todos los dispositivos de captura e identifica automáticamente los micrófonos USB.

### 6b. Probar el micrófono

```bash
# Grabar 3 segundos y reproducir
scripts/audio-check.sh --test plughw:1,0

# Ver nivel de señal en tiempo real
scripts/audio-check.sh --level plughw:1,0
```

Sustituir `plughw:1,0` por el dispositivo que apareció en `arecord -l`.

### 6c. Fix obligatorio para Focusrite Scarlett en Pi 3B

Si usas una Focusrite Scarlett (UAC2), aplicar el fix del controlador USB antes de grabar:

```bash
# Verificar si ya está aplicado
scripts/scarlett-pi3b-fix.sh --check

# Aplicar (requiere sudo — reinicia automáticamente)
sudo scripts/scarlett-pi3b-fix.sh
```

Ver [docs/audio.md](audio.md) para la guía completa de audio.

---

## Paso 7 — Primera captura con audio y video

### Cámara USB

```bash
# Solo video — 30 segundos (detección automática de cámara)
scripts/usb-camera.sh --capture -t 30

# Video + audio USB (detección automática de micrófono)
scripts/usb-camera.sh --capture -t 30

# Especificando dispositivos
scripts/usb-camera.sh --capture \
    --dev /dev/video0 \
    --audio-dev plughw:1,0 \
    --audio-rate 48000 \
    -t 30

# Sin audio
scripts/usb-camera.sh --capture -t 30 --no-audio
```

### Módulo CSI

```bash
# Solo video
scripts/capture.sh -t 30

# Video + audio USB
scripts/capture.sh --audio -t 30

# Video + audio especificando dispositivo
scripts/capture.sh --audio --audio-dev plughw:1,0 --audio-rate 48000 -t 30
```

---

## Paso 8 — Primer stream RTMP

### Cámara USB

```bash
# Stream básico (reemplazar con tu stream key)
scripts/usb-camera.sh -u rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY

# Stream con audio USB detectado automáticamente
scripts/usb-camera.sh \
    -u rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY \
    --audio-dev plughw:1,0

# Stream sin audio
scripts/usb-camera.sh \
    -u rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY \
    --no-audio
```

### Módulo CSI

```bash
scripts/stream.sh -u rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY
```

Ctrl+C para detener el stream.

---

## Paso 9 — Generar assets de overlays (opcional)

```bash
scripts/generate-assets.sh
```

Genera `assets/logo.png` y `assets/frame.png` de ejemplo con ffmpeg.

Stream con overlay (módulo CSI):

```bash
scripts/stream-overlay.sh \
    -u rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY \
    --logo assets/logo.png \
    --timestamp
```

Ver [docs/overlays.md](overlays.md) para todas las opciones de overlay.

---

## Paso 10 — Automatización con systemd (opcional)

Para que el stream arranque automáticamente al encender la Pi:

### Instalar el servicio

```bash
sudo scripts/control.sh install
```

### Configurar la URL RTMP

```bash
sudo nano /etc/streaming.env
```

Editar la variable `RTMP_URL`:

```
RTMP_URL=rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY
```

Guardar y cerrar (`Ctrl+X`, `Y`, `Enter`).

### Iniciar y habilitar el servicio

```bash
scripts/control.sh start    # Iniciar ahora
scripts/control.sh status   # Verificar que está corriendo
scripts/control.sh enable   # Inicio automático en cada boot
```

### Comandos útiles de control

```bash
scripts/control.sh stop      # Detener el stream
scripts/control.sh restart   # Reiniciar el stream
scripts/control.sh logs      # Ver logs en tiempo real
```

---

## Resumen — inicio rápido con cámara USB

```bash
# 1. Actualizar sistema
sudo apt update && sudo apt upgrade -y

# 2. Instalar dependencias (cámara USB)
sudo apt install -y ffmpeg v4l-utils alsa-utils git

# 3. Clonar el repositorio
git clone https://github.com/rafex/raspberrypi-headless-streaming.git
cd raspberrypi-headless-streaming
chmod +x scripts/*.sh

# 4. Conectar la cámara USB y verificar
scripts/usb-camera.sh --list

# 5. Probar captura (5 segundos)
scripts/usb-camera.sh --capture -t 5

# 6. Detectar micrófono USB (si aplica)
scripts/audio-check.sh

# 7. Primer stream
scripts/usb-camera.sh -u rtmp://TU_URL/TU_KEY
```

## Resumen — inicio rápido con módulo CSI

```bash
# 1. Actualizar sistema
sudo apt update && sudo apt upgrade -y

# 2. Instalar dependencias (módulo CSI)
sudo apt install -y libcamera-apps ffmpeg alsa-utils git

# 3. Activar cámara (SOLO para módulo CSI)
sudo raspi-config   # Interface Options → Camera → Enable
sudo reboot

# 4. Clonar el repositorio
git clone https://github.com/rafex/raspberrypi-headless-streaming.git
cd raspberrypi-headless-streaming
chmod +x scripts/*.sh

# 5. Verificar cámara
libcamera-hello --list-cameras

# 6. Probar captura (5 segundos)
scripts/capture.sh -t 5

# 7. Detectar micrófono USB (si aplica)
scripts/audio-check.sh

# 8. Primer stream
scripts/stream.sh -u rtmp://TU_URL/TU_KEY
```

---

## Solución de problemas comunes

### La cámara USB no aparece en `/dev/video*`

```bash
# Ver si el kernel la detectó
dmesg | grep -i "usb\|video\|uvc" | tail -20

# Listar dispositivos USB
lsusb
```

Si aparece en `lsusb` pero no en `/dev/video*`, puede que el módulo UVC no esté cargado:

```bash
sudo modprobe uvcvideo
```

### `v4l2-ctl: command not found`

```bash
sudo apt install -y v4l-utils
```

### `libcamera-vid: command not found`

```bash
sudo apt install -y libcamera-apps
```

### `No cameras available` (módulo CSI)

- Verificar que la cámara esté habilitada en `raspi-config` o `dietpi-config`
- Verificar el cable flat (desconectar y reconectar con la Pi apagada)
- `dmesg | grep -i camera`

### La cámara USB solo graba imagen verde o negra

El formato de entrada puede no ser MJPEG. Probar con YUYV:

```bash
ffmpeg -f v4l2 -input_format yuyv422 -video_size 1280x720 -i /dev/video0 -t 5 /tmp/test.mp4
```

### El stream se corta o tiene artefactos

- Reducir bitrate: `-b 2000000`
- Reducir resolución: `-w 640 -h 480`
- Verificar temperatura: `vcgencmd measure_temp` — si supera 80°C hay throttling

### El audio tiene ruido o dropout

- Si usas Focusrite Scarlett: aplicar `sudo scripts/scarlett-pi3b-fix.sh`
- Usar `plughw:` en lugar de `hw:` para conversión automática de formato
- Ajustar ganancia con `alsamixer -c 1`

### La Pi se throttlea (baja velocidad por temperatura o voltaje)

```bash
vcgencmd get_throttled    # 0x0 = sin problemas
vcgencmd measure_temp     # temperatura actual
```

Usar disipador térmico y fuente de 5V/3A.

---

## Próximos pasos

| Tema | Documento |
|---|---|
| Overlays, logos, texto | [docs/overlays.md](overlays.md) |
| Audio USB y micrófonos | [docs/audio.md](audio.md) |
| Arquitectura del pipeline | [docs/architecture.md](architecture.md) |
| Integración con IA (DeepSeek / OpenRouter) | [docs/ai-integration.md](ai-integration.md) |
