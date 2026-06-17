# TUI interactivo: stream-tui.sh

Asistente de configuración en terminal (TUI) para lanzar un stream RTMP
desde una cámara USB sin necesidad de escribir ningún argumento. Guía al
usuario en 5 pasos y luego inicia `ffmpeg` directamente.

```
scripts/stream-tui.sh
```

> Requiere ejecutarse en un terminal con acceso al dispositivo de video y audio
> (el usuario debe pertenecer a los grupos `video` y `audio`, o ejecutar con `sudo`).

---

## Variables de entorno (opcionales)

Si estas variables están definidas en el entorno, el TUI las usa sin preguntar la stream key:

| Variable | Descripción |
|---|---|
| `YOUTUBE_STREAM_KEY` | Stream key de YouTube Live |
| `META_STREAM_KEY` | Stream key de Facebook / Meta Live |

```bash
export YOUTUBE_STREAM_KEY="xxxx-xxxx-xxxx-xxxx"
scripts/stream-tui.sh
```

---

## Pasos del asistente

### Paso 1 — Cámara USB y resolución

Detecta automáticamente todas las cámaras USB con soporte de video
(`/dev/video*` con formatos MJPEG, YUYV o H264). Si hay más de una,
muestra un menú de selección.

Resoluciones disponibles:

| Opción | Resolución | Uso recomendado |
|---|---|---|
| 1 | 1920×1080 (Full HD) | Buena red + Pi 4B |
| 2 | 1280×720 (HD) | **Recomendado Pi 3B** |
| 3 | 854×480 (480p) | Menor uso de CPU |
| 4 | 640×360 (360p) | Mínimo CPU / red limitada |

Si la cámara soporta MJPEG, el TUI lo usa como formato de entrada
(menor carga de CPU que YUYV).

---

### Paso 2 — Micrófono

Detecta micrófonos via `arecord -l`. Si hay más de uno, muestra menú.
La última opción siempre es "Sin audio".

- **Mono** — recomendado para voz (BOYA, micrófono de solapa).
- **Stereo** — para música o cámara con micrófono integrado.

Micrófonos BOYA / Focusrite Scarlett detectan automáticamente 48 000 Hz;
el resto usan 44 100 Hz por defecto.

---

### Paso 3 — Plataforma y Stream Key

| Opción | Destino |
|---|---|
| YouTube Live | `rtmp://a.rtmp.youtube.com/live2/<KEY>` |
| Facebook / Meta Live | `rtmps://live-api-s.facebook.com:443/rtmp/<KEY>` |
| URL personalizada | Cualquier destino RTMP/RTMPS |
| ★ Dual stream | YouTube **y** Facebook simultáneamente _(experimental)_ |

**Dual stream:** usa el muxer `tee` de ffmpeg con `onfail=ignore` — si
una plataforma cae, la otra continúa transmitiendo. Requiere suficiente
ancho de banda de subida para dos streams.

---

### Paso 4 — Bitrate de video

| Opción | Bitrate | Uso recomendado |
|---|---|---|
| Alta calidad | 4 500 kbps | Red rápida, Pi 4B |
| Balance | 2 500 kbps | **Recomendado** |
| Bajo ancho de banda | 1 500 kbps | Red limitada |
| Mínimo | 800 kbps | Conexión muy lenta |

---

### Paso 5 — Overlays

#### Logo PNG

- Acepta **ruta local** (`/home/pi/logo.png`) o **URL** (`https://...`).
- Si es una URL, la descarga a `/tmp` con `wget` o `curl` antes de iniciar.
- Redimensiona el logo al ancho elegido usando `ffmpeg` (o `convert` como fallback).

Tamaños recomendados:

| Resolución | Ancho sugerido |
|---|---|
| 360p / 480p | 60 – 80 px |
| 720p | 100 – 150 px |
| 1080p | 120 – 200 px |

Posiciones disponibles: `br` (abajo derecha, default), `bl`, `tr`, `tl`.
Margen configurable en píxeles desde el borde (default: 20 px).
Formato ideal: PNG con canal alfa (fondo transparente).

#### Banner de texto

Barra semitransparente con texto centrado, ubicada en:
- `footer` — barra inferior (default)
- `header` — barra superior

---

## Resumen y confirmación

Antes de lanzar el stream, el TUI muestra un resumen con todos los
parámetros configurados y pide confirmación (`S/n`).

---

## Diferencias respecto a stream-overlay.sh

`stream-tui.sh` es un wrapper interactivo que internamente llama a:
- `scripts/usb-camera.sh` — cuando no hay overlays ni dual stream (path simple).
- `ffmpeg` directamente — con overlays o en modo dual stream.

`stream-overlay.sh` en cambio es el script que usa el servicio systemd
(`streaming-overlay.service`) controlado desde la web API. Acepta todos
los parámetros por argumentos o variables de entorno, sin interacción.

---

## Requisitos

```bash
sudo apt install -y ffmpeg v4l-utils alsa-utils
# Para descarga de logo desde URL (uno de los dos):
sudo apt install -y wget
# o
sudo apt install -y curl
# Para redimensionar logo con ImageMagick (opcional, ffmpeg ya puede hacerlo):
sudo apt install -y imagemagick
```
