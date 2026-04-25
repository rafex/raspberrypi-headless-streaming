# Audio USB

Guía de configuración y uso de micrófono USB en el pipeline de streaming headless.

---

## Requisitos

```bash
sudo apt install -y alsa-utils
```

`alsa-utils` incluye `arecord`, `aplay` y `alsamixer`.  
`ffmpeg` ya es una dependencia del proyecto.

---

## 1. Detectar el micrófono USB

Conectar el micrófono USB y ejecutar:

```bash
scripts/audio-check.sh
```

O directamente con ALSA:

```bash
arecord -l
```

Salida de ejemplo:

```
**** List of CAPTURE Hardware Devices ****
card 0: b1 [bcm2835 HDMI 1], device 0: bcm2835 HDMI 1 [bcm2835 HDMI 1]
card 1: Device [USB PnP Sound Device], device 0: USB Audio [USB Audio]
```

El micrófono USB aparece como `card 1, device 0` → usar `hw:1,0` o `plughw:1,0`.

### Diferencia entre hw: y plughw:

| Prefijo | Descripción | Cuándo usar |
|---|---|---|
| `hw:1,0` | Acceso directo al hardware, sin conversión | cuando el hardware soporta el sample rate exacto |
| `plughw:1,0` | Con conversión automática de formato y sample rate | **recomendado para micrófonos USB** |

---

## 2. Verificar que el micrófono funciona

```bash
# Probar grabación de 3 segundos y reproducción
scripts/audio-check.sh --test hw:1,0

# Ver nivel de señal en tiempo real (VU meter en terminal)
scripts/audio-check.sh --level hw:1,0
```

Grabación manual con arecord:

```bash
# Grabar 5 segundos en WAV
arecord -D hw:1,0 -d 5 -f cd /tmp/test.wav

# Reproducir (si hay altavoz)
aplay /tmp/test.wav
```

---

## 3. Ajustar niveles con alsamixer

```bash
alsamixer
```

Navegar con:
- `F6` → seleccionar tarjeta de sonido (elegir el USB mic)
- `F4` → ver controles de captura
- `↑↓` → subir/bajar volumen
- `Space` → activar/desactivar captura
- `M` → mute/unmute
- `Esc` → salir

Guardar la configuración:

```bash
sudo alsactl store
```

Para restaurarla al iniciar (agregar en `/etc/rc.local` o via systemd):

```bash
alsactl restore
```

---

## 4. Configurar el micrófono USB como dispositivo default

Esto permite que `hw:0` se refiera automáticamente al USB mic:

```bash
scripts/audio-check.sh --set-default hw:1,0
```

O manualmente en `~/.asoundrc`:

```
pcm.!default {
    type asym
    capture.pcm "mic"
    playback.pcm "speaker"
}

pcm.mic {
    type plug
    slave {
        pcm "hw:1,0"
    }
}

pcm.speaker {
    type plug
    slave {
        pcm "hw:0,0"
    }
}

ctl.!default {
    type hw
    card 1
}
```

Para aplicar a todos los usuarios:

```bash
sudo cp ~/.asoundrc /etc/asound.conf
```

---

## 5. Uso del micrófono en los scripts

### Captura de video + audio local

```bash
# Detección automática del USB mic
scripts/capture.sh --audio -t 60

# Especificar dispositivo manualmente
scripts/capture.sh --audio --audio-dev hw:1,0 -t 60

# Mono, 16kHz (menor uso de CPU, suficiente para voz)
scripts/capture.sh --audio --audio-dev hw:1,0 --audio-rate 16000 --audio-ch 1
```

### Streaming RTMP con audio

```bash
# Detección automática
scripts/stream.sh -u rtmp://...

# Especificar dispositivo
scripts/stream.sh -u rtmp://... --audio-dev hw:1,0

# Variable de entorno
AUDIO_DEVICE=hw:1,0 scripts/stream.sh -u rtmp://...

# Sin audio
scripts/stream.sh -u rtmp://... --no-audio
```

### Streaming con overlays y audio

```bash
scripts/stream-overlay.sh -u rtmp://... \
    --logo assets/logo.png \
    --timestamp \
    --audio-dev hw:1,0
```

---

## 6. Parámetros de audio recomendados para Pi 3B

| Parámetro | Valor recomendado | Motivo |
|---|---|---|
| Sample rate | 44100 Hz | estándar compatible con todos los mics USB |
| Canales | 1 (mono) | menor CPU y ancho de banda |
| Codec | AAC | compatible con RTMP / MP4 |
| Bitrate | 96–128 kbps | balance calidad / ancho de banda |
| Dispositivo | `plughw:1,0` | conversión automática de formato |

Para streams de voz (demo, conferencia):

```bash
--audio-rate 16000 --audio-ch 1 -a 64000
```

Para streams de alta calidad (música, ambiente):

```bash
--audio-rate 44100 --audio-ch 2 -a 192000
```

---

## 7. Latencia audio/video en Pi 3B

El pipeline `libcamera-vid | ffmpeg` introduce latencia diferente en video y audio:

| Fuente | Latencia típica |
|---|---|
| Video (H264 hardware) | ~100–200 ms |
| Audio ALSA captura | ~50–100 ms |
| ffmpeg mux buffer | ~200–500 ms |
| **Total extremo a extremo** | **~500 ms – 1.5s** |

### Compensar desincronización A/V

Si el audio llega antes o después que el video, usar el parámetro `-itsoffset` en ffmpeg.

Ejemplo con audio adelantado 200ms:

```bash
libcamera-vid ... --output - | ffmpeg \
    -re -i - \
    -itsoffset 0.2 \
    -f alsa -i hw:1,0 \
    -vcodec copy -acodec aac \
    -f flv rtmp://...
```

Ejemplo con video adelantado 300ms:

```bash
libcamera-vid ... --output - | ffmpeg \
    -re -i - \
    -f alsa -i hw:1,0 \
    -af "adelay=300|300" \
    -vcodec copy -acodec aac \
    -f flv rtmp://...
```

### Reducir latencia de buffer de ffmpeg

```bash
-fflags nobuffer -flags low_delay -probesize 32 -analyzeduration 0
```

Útil para demos en tiempo real donde la sincronización es crítica.

---

## 8. Solución de problemas comunes

### El micrófono no aparece en arecord -l

```bash
# Verificar que el kernel lo detectó
dmesg | grep -i "usb\|audio\|sound" | tail -20

# Listar dispositivos USB conectados
lsusb
```

### Error: "Device or resource busy"

El dispositivo ya está siendo usado por otro proceso:

```bash
# Ver qué proceso usa la tarjeta de sonido
fuser /dev/snd/*

# Matar el proceso si es necesario
fuser -k /dev/snd/*
```

### Error: "Invalid argument" al usar hw:1,0

El micrófono no soporta el sample rate solicitado. Usar `plughw:` que convierte automáticamente:

```bash
# En lugar de hw:1,0
--audio-dev plughw:1,0
```

Verificar sample rates soportados:

```bash
arecord -D hw:1,0 --dump-hw-params /dev/null 2>&1 | grep "RATE"
```

### Audio con ruido o distorsión

Ajustar el nivel de ganancia con alsamixer (bajar si hay saturación).  
También verificar la calidad del cable USB y evitar interferencias electromagnéticas cerca de la Pi.

---

## 9. Micrófonos USB probados y compatibles

Cualquier micrófono USB que implemente la clase de audio estándar USB Audio Class (UAC) 1.0 o 2.0 funciona sin drivers adicionales.

Características a buscar:

- **UAC 1.0** — compatible con Pi 3B sin configuración extra
- **UAC 2.0** — requiere kernel 4.x+ (DietPi/Raspberry Pi OS actual lo incluye)
- **Plug & Play** — sin necesidad de instalar drivers

Verificar en `dmesg` tras conectar:

```
usb X-X: New USB device found
usb X-X: Product: USB PnP Sound Device
```

Si aparece `USB Audio Class`, el dispositivo es compatible.
