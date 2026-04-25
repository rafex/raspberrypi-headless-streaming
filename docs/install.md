# Instalación en Raspberry Pi 3B

Guía paso a paso para instalar y poner en marcha el sistema de streaming headless desde cero.

---

## Requisitos previos

| Componente | Mínimo |
|---|---|
| Placa | Raspberry Pi 3B / 3B+ |
| OS | Raspberry Pi OS Lite (64-bit recomendado) o DietPi |
| Cámara | Camera Module v1, v2, v3 o USB UVC |
| microSD | 8 GB clase 10 o superior |
| Red | Ethernet (recomendado) o Wi-Fi |
| Acceso | SSH o teclado/monitor |

> Esta guía asume acceso por terminal (sin escritorio). Si usas DietPi, los pasos de cámara difieren ligeramente — se indican.

---

## Paso 1 — Actualizar el sistema

```bash
sudo apt update && sudo apt upgrade -y
```

---

## Paso 2 — Instalar dependencias

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
| `libcamera-apps` | captura de video por hardware (`libcamera-vid`) |
| `ffmpeg` | muxing, overlays, streaming RTMP, audio |
| `alsa-utils` | detección y prueba de micrófono USB (`arecord`, `alsamixer`) |
| `git` | clonar el repositorio |
| `curl` | descargar mediamtx (opcional) |

---

## Paso 3 — Activar la cámara

### En Raspberry Pi OS

```bash
sudo raspi-config
```

Navegar a:

```
Interface Options → Camera → Enable
```

Reiniciar:

```bash
sudo reboot
```

### En DietPi

```bash
sudo dietpi-config
```

Navegar a:

```
Advanced Options → Camera → Enable
```

Reiniciar:

```bash
sudo reboot
```

### Verificar que la cámara es detectada

```bash
libcamera-hello --list-cameras
```

Salida esperada:

```
Available cameras
-----------------
0 : imx219 [3280x2464 10-bit RGGB] (...)
```

Si no aparece ninguna cámara, verificar el cable flat y que el módulo esté bien asentado.

---

## Paso 4 — Clonar el repositorio

```bash
git clone https://github.com/rafex/raspberrypi-headless-streaming.git
cd raspberrypi-headless-streaming
```

Dar permisos de ejecución a todos los scripts:

```bash
chmod +x scripts/*.sh
```

---

## Paso 5 — Verificar la instalación

Probar que la cámara captura video:

```bash
# Grabar 5 segundos de prueba
scripts/capture.sh -t 5 -o /tmp/test.h264

# Ver el tamaño del archivo generado
ls -lh /tmp/test.h264
```

Si el archivo existe y tiene tamaño mayor a 0, la cámara y el encoding H264 funcionan correctamente.

---

## Paso 6 — Micrófono USB (opcional)

Si vas a capturar audio con micrófono USB o BOYALINK CC / Focusrite Scarlett:

### 6a. Instalar herramientas ALSA

Ya incluido en el Paso 2. Verificar:

```bash
arecord -l
```

### 6b. Conectar el micrófono y detectarlo

```bash
scripts/audio-check.sh
```

El script lista todos los dispositivos de captura e identifica automáticamente los micrófonos USB.

### 6c. Probar el micrófono

```bash
# Grabar 3 segundos y reproducir
scripts/audio-check.sh --test plughw:1,0

# Ver nivel de señal en tiempo real
scripts/audio-check.sh --level plughw:1,0
```

Sustituir `plughw:1,0` por el dispositivo que apareció en `arecord -l`.

### 6d. Fix obligatorio para Focusrite Scarlett en Pi 3B

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

```bash
# Solo video — 30 segundos
scripts/capture.sh -t 30

# Video + audio USB — 30 segundos
scripts/capture.sh --audio -t 30

# Video + audio especificando dispositivo y sample rate
scripts/capture.sh --audio --audio-dev plughw:1,0 --audio-rate 48000 -t 30
```

El archivo generado se llama `capture_YYYYMMDD_HHMMSS.mp4` (con audio) o `.h264` (solo video).

---

## Paso 8 — Primer stream RTMP

```bash
# Stream básico a YouTube (reemplazar con tu stream key)
scripts/stream.sh -u rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY

# Stream con audio USB detectado automáticamente
scripts/stream.sh -u rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY --audio-dev plughw:1,0

# Stream sin audio
scripts/stream.sh -u rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY --no-audio
```

Ctrl+C para detener el stream.

---

## Paso 9 — Generar assets de overlays (opcional)

Si quieres probar overlays antes de tener tus propios logos:

```bash
scripts/generate-assets.sh
```

Genera `assets/logo.png` y `assets/frame.png` de ejemplo con ffmpeg.

Stream con overlay:

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
# Iniciar ahora
scripts/control.sh start

# Verificar que está corriendo
scripts/control.sh status

# Habilitar inicio automático en cada boot
scripts/control.sh enable
```

### Comandos útiles de control

```bash
scripts/control.sh stop      # Detener el stream
scripts/control.sh restart   # Reiniciar el stream
scripts/control.sh logs      # Ver logs en tiempo real
```

---

## Resumen de comandos — inicio rápido

```bash
# 1. Actualizar sistema
sudo apt update && sudo apt upgrade -y

# 2. Instalar dependencias
sudo apt install -y libcamera-apps ffmpeg alsa-utils git curl

# 3. Activar cámara (Raspberry Pi OS)
sudo raspi-config   # Interface Options → Camera → Enable
sudo reboot

# 4. Clonar el repositorio
git clone https://github.com/rafex/raspberrypi-headless-streaming.git
cd raspberrypi-headless-streaming
chmod +x scripts/*.sh

# 5. Verificar cámara
libcamera-hello --list-cameras

# 6. Probar captura
scripts/capture.sh -t 5

# 7. Detectar micrófono USB (si aplica)
scripts/audio-check.sh

# 8. Primer stream
scripts/stream.sh -u rtmp://TU_URL/TU_KEY
```

---

## Solución de problemas comunes

### `libcamera-vid: command not found`

```bash
sudo apt install -y libcamera-apps
```

### `No cameras available`

- Verificar que el módulo de cámara esté habilitado (`raspi-config` o `dietpi-config`)
- Verificar el cable flat de la cámara (desconectar y reconectar con la Pi apagada)
- Ejecutar `dmesg | grep -i camera` para ver errores del kernel

### `ffmpeg: command not found`

```bash
sudo apt install -y ffmpeg
```

### El stream se corta o tiene artefactos

- Reducir bitrate: `-b 3000000`
- Reducir resolución: `-w 1280 -h 720`
- Verificar temperatura: `vcgencmd measure_temp` — si supera 80°C hay throttling

### El audio tiene ruido o dropout

- Si usas Focusrite Scarlett: aplicar `sudo scripts/scarlett-pi3b-fix.sh`
- Usar `plughw:` en lugar de `hw:` para conversión automática de formato
- Ajustar ganancia con `alsamixer -c 1`

### La Pi se throttlea (baja velocidad por temperatura o voltaje)

```bash
# Ver estado de throttling
vcgencmd get_throttled
# 0x0 = sin problemas
# 0x50000 = throttling por temperatura
# 0x50005 = throttling por voltaje bajo

# Ver temperatura actual
vcgencmd measure_temp
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
