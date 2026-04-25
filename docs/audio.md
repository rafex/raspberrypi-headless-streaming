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

---

## 10. BOYA LINK CC en Raspberry Pi 3B

Guía específica para el micrófono inalámbrico **BOYALINK CC** (receptor USB-C, 2.4 GHz, 48kHz/24bit).

### Especificaciones relevantes

| Parámetro | Valor |
|---|---|
| Conexión receptor | USB-C |
| Protocolo | USB Audio Class (UAC) — sin drivers |
| Sample rate | **48000 Hz** |
| Bit depth | 24-bit |
| Frecuencia inalámbrica | 2.4 GHz |
| Rango | hasta 100 m |

### Requisito: adaptador USB-C → USB-A

La Pi 3B solo tiene puertos **USB-A**. El receptor BOYALINK CC usa **USB-C**.  
Se necesita un adaptador pasivo **USB-C hembra → USB-A macho**:

```
Receptor BOYALINK CC (USB-C) → adaptador → Puerto USB-A de Pi 3B
```

Cualquier adaptador pasivo OTG o de conversión simple sirve. No requiere alimentación extra.

### Conexión y detección

1. Encender el transmisor (lavalier)
2. Conectar el receptor al adaptador y luego a la Pi 3B
3. Verificar detección:

```bash
# Verificar que el kernel lo vio
dmesg | tail -20 | grep -i "usb\|audio\|boya"

# Listar dispositivos USB
lsusb

# Listar dispositivos de captura ALSA
arecord -l
```

Salida esperada en `arecord -l`:

```
card 1: Device [USB Audio Device], device 0: USB Audio [USB Audio]
```

o con nombre BOYA explícito:

```
card 1: BOYALINK [BOYA LINK CC], device 0: USB Audio [USB Audio]
```

Detección automática con el script:

```bash
scripts/audio-check.sh
```

### Sample rate: 48000 Hz obligatorio

El BOYALINK CC opera a **48kHz**. Usar siempre `--audio-rate 48000`:

```bash
# Verificar que 48kHz está soportado
arecord -D hw:1,0 --dump-hw-params /dev/null 2>&1 | grep "RATE"
```

Si usas `plughw:1,0` (recomendado), la conversión de rate es automática.

### Prueba de grabación

```bash
# Verificar que el micrófono graba correctamente
scripts/audio-check.sh --test plughw:1,0

# Ver nivel de señal en tiempo real
scripts/audio-check.sh --level plughw:1,0
```

### Captura video + audio BOYALINK CC

```bash
# Grabación local MP4 con detección automática
scripts/capture.sh --audio -t 60

# Especificando dispositivo y sample rate explícitamente
scripts/capture.sh --audio --audio-dev plughw:1,0 --audio-rate 48000 -t 60
```

### Streaming con BOYALINK CC

```bash
# Stream RTMP con audio inalámbrico (detección automática)
scripts/stream.sh -u rtmp://a.rtmp.youtube.com/live2/KEY

# Especificando dispositivo
scripts/stream.sh -u rtmp://... --audio-dev plughw:1,0 --audio-rate 48000

# Stream con overlays
scripts/stream-overlay.sh -u rtmp://... \
    --logo assets/logo.png \
    --timestamp \
    --audio-dev plughw:1,0 \
    --audio-rate 48000
```

### Configurar BOYALINK CC como dispositivo default

```bash
scripts/audio-check.sh --set-default hw:1,0
```

Esto crea `~/.asoundrc` con el USB mic como default para todos los scripts.

### Latencia adicional por inalámbrico

El sistema 2.4 GHz del BOYALINK introduce ~20 ms de latencia de transmisión.  
Sumado a la latencia A/V del pipeline ffmpeg (~200-500 ms), el audio puede llegar ligeramente detrás del video.

Compensar con `adelay` en ffmpeg si se nota desincronización:

```bash
# Retrasar el audio 200ms para sincronizarlo con el video
scripts/stream.sh -u rtmp://... --audio-dev plughw:1,0 --audio-rate 48000
# Si hay desync, editar stream.sh y agregar: -af "adelay=200|200"
```

### Ganancia y cancelación de ruido

El BOYALINK tiene control de ganancia por hardware (6 niveles en el BOYALINK 2).  
Ajustar directamente en el transmisor/receptor antes de grabar.  
En ALSA, el nivel de captura se puede ajustar con:

```bash
alsamixer -c 1   # -c N donde N es el número de card del BOYALINK
```

Subir `Mic` o `Capture` hasta ~80% para evitar saturación.

### Solución de problemas específicos BOYALINK

**El receptor no aparece en `arecord -l`:**
```bash
# Verificar que el adaptador USB-C → USB-A funciona
lsusb
# Si no aparece ningún dispositivo BOYA, probar otro adaptador
# Algunos adaptadores OTG no pasan audio correctamente
```

**Error: "cannot set sample rate":**
```bash
# El receptor requiere 48000 Hz obligatoriamente
--audio-rate 48000
# O usar plughw: en lugar de hw:
--audio-dev plughw:1,0
```

**Interferencias o dropout de audio:**
- Alejar la Pi 3B de routers Wi-Fi (misma banda 2.4 GHz)
- Mantener transmisor y receptor en línea de visión directa
- Verificar que la batería del transmisor tiene carga suficiente

---

## 11. Focusrite Scarlett en Raspberry Pi 3B

Guía para usar interfaces de audio **Focusrite Scarlett** (Solo, 2i2, 4i4, etc.) con la Pi 3B.

Todos los modelos Focusrite Scarlett implementan **USB Audio Class (UAC)** — funcionan sin instalar drivers en Linux, incluyendo Raspberry Pi OS y DietPi.

### Compatibilidad por generación

| Modelo | UAC | Gen | Notas |
|---|---|---|---|
| Scarlett Solo (Gen 1-4) | UAC2 | 1ª–4ª | Mono/stereo, ideal para una fuente |
| Scarlett 2i2 (Gen 1-4) | UAC2 | 1ª–4ª | 2 entradas XLR/TRS, más común |
| Scarlett 4i4 (Gen 3-4) | UAC2 | 3ª–4ª | 4 entradas, mayor consumo USB |
| Scarlett 18i20 | UAC2 | 3ª–4ª | Requiere alimentación externa en Pi 3B |

> **UAC2** requiere kernel 4.x o superior — Raspberry Pi OS actual (basado en Debian Bookworm/Bullseye) lo incluye por defecto.

### Fix obligatorio en Pi 3B: controlador USB

La Pi 3B usa el controlador USB `dwc_otg` que tiene un bug con dispositivos UAC2 (incluyendo Scarlett): produce ruido, dropout, o fallos de detección.

**Solución:** usar el script incluido:

```bash
# Verificar si el fix ya está aplicado
scripts/scarlett-pi3b-fix.sh --check

# Aplicar el fix y reiniciar
sudo scripts/scarlett-pi3b-fix.sh

# Aplicar sin reiniciar inmediatamente
sudo scripts/scarlett-pi3b-fix.sh --no-reboot

# Revertir si fuera necesario
sudo scripts/scarlett-pi3b-fix.sh --revert
```

O manualmente:

```bash
# Agregar el parámetro al final de la línea existente (NO agregar nueva línea)
sudo sed -i 's/$/ dwc_otg.fiq_fsm_enable=0/' /boot/cmdline.txt

# Verificar
cat /boot/cmdline.txt
# Debe verse: ... rootwait dwc_otg.fiq_fsm_enable=0

# Reiniciar para aplicar
sudo reboot
```

> **IMPORTANTE:** `/boot/cmdline.txt` es una sola línea. No agregar saltos de línea.

Sin este fix, la Scarlett puede aparecer en `arecord -l` pero producir ruido o fallar al grabar.

### Conexión y detección

1. Conectar la Scarlett al puerto USB-A de la Pi 3B
2. Verificar detección:

```bash
# Ver log del kernel
dmesg | tail -20 | grep -i "usb\|audio\|scarlett\|focusrite"

# Listar dispositivos USB
lsusb
# Debe aparecer: Focusrite-Novation Scarlett...

# Listar dispositivos de captura ALSA
arecord -l
```

Salida esperada en `arecord -l`:

```
card 1: Scarlett2i2USB [Scarlett 2i2 USB], device 0: USB Audio [USB Audio]
```

o para el Solo:

```
card 1: ScarlettSoloUSB [Scarlett Solo USB], device 0: USB Audio [USB Audio]
```

Detección automática con el script:

```bash
scripts/audio-check.sh
```

### Sample rate recomendado

La Scarlett soporta múltiples sample rates: **44100, 48000, 88200, 96000 Hz**.  
Para streaming en Pi 3B, usar **48000 Hz** (nativo de la Scarlett) o **44100 Hz** (estándar RTMP):

```bash
# Verificar sample rates disponibles
arecord -D hw:1,0 --dump-hw-params /dev/null 2>&1 | grep "RATE"
```

Usar siempre `plughw:` para conversión automática si hay mismatch:

```bash
--audio-dev plughw:1,0 --audio-rate 48000
```

### Ajustar ganancia con alsamixer

```bash
# Abrir mezclador para la Scarlett (card 1 en este ejemplo)
alsamixer -c 1
```

- `F4` → controles de captura (Mic, Line In)
- `↑↓` → subir/bajar ganancia
- Objetivo: pico en -6 dB a -12 dB para evitar clipping

Guardar configuración para que persista al reiniciar:

```bash
sudo alsactl store
```

### Captura y streaming con Scarlett

```bash
# Grabación local con detección automática
scripts/capture.sh --audio -t 60

# Especificando dispositivo explícitamente (stereo, 48kHz)
scripts/capture.sh --audio --audio-dev plughw:1,0 --audio-rate 48000 --audio-ch 2 -t 60

# Stream RTMP con Scarlett
scripts/stream.sh -u rtmp://... --audio-dev plughw:1,0 --audio-rate 48000

# Stream con overlays
scripts/stream-overlay.sh -u rtmp://... \
    --logo assets/logo.png \
    --timestamp \
    --audio-dev plughw:1,0 \
    --audio-rate 48000
```

### Alimentación USB en Pi 3B

La Pi 3B puede suministrar hasta **1.2 A total** en sus puertos USB.  
Las Scarlett consumen:

| Modelo | Consumo USB |
|---|---|
| Solo | ~150 mA |
| 2i2 | ~200 mA |
| 4i4 | ~400 mA |
| 18i20 | > 500 mA — usar hub con alimentación externa |

Para Solo y 2i2 no hay problema. Si la Pi 3B tiene cámara + USB hub + Scarlett, verificar con:

```bash
# Ver si hay throttling por alimentación insuficiente
vcgencmd get_throttled
# 0x0 = sin problemas
```

Usar fuente de 5V/3A para la Pi 3B si se conectan varios periféricos.

### Solución de problemas específicos Scarlett

**La Scarlett no aparece en `arecord -l` o produce ruido:**
```bash
# Verificar si el fix está aplicado
scripts/scarlett-pi3b-fix.sh --check

# Si no está aplicado:
sudo scripts/scarlett-pi3b-fix.sh
```

**Error: "cannot set sample rate" o "Invalid argument":**
```bash
# Usar plughw: con conversión automática
--audio-dev plughw:1,0
# O verificar los rates soportados:
arecord -D hw:1,0 --dump-hw-params /dev/null 2>&1 | grep RATE
```

**Audio con latencia o clicks (xrun):**
```bash
# Aumentar el buffer de ALSA en ffmpeg
ffmpeg ... -f alsa -i plughw:1,0 -thread_queue_size 1024 ...
```

**Scarlett no reconocida tras reinicio:**
```bash
# Desconectar y reconectar el USB
# Verificar dmesg para errores
dmesg | tail -30 | grep -i "usb\|error"
```
