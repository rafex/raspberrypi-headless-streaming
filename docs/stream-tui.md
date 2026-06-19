# TUI interactivo: stream-tui.sh y preview-tui.sh

Dos asistentes de configuración en terminal (TUI) para cámara USB, sin
necesidad de escribir ningún argumento:

| Script | Para qué sirve |
|---|---|
| `scripts/stream-tui.sh` | Transmitir en vivo (RTMP) **o** grabar a un archivo MP4 local |
| `scripts/preview-tui.sh` | Probar cámara/audio/overlays antes de salir en vivo, viendo el resultado en VLC desde otra máquina |

Ambos comparten el mismo motor (`scripts/lib/common.sh`): detección de
cámara/micrófono, selección de bitrate, overlays (logo/banner/fecha-hora)
y el armado del pipeline de `ffmpeg`. Solo difieren en **qué hacen con
el video ya capturado**: uno lo transmite o grava, el otro lo manda a un
destino de prueba.

```bash
scripts/stream-tui.sh
scripts/preview-tui.sh
```

> Requiere ejecutarse en un terminal con acceso al dispositivo de video y audio
> (el usuario debe pertenecer a los grupos `video` y `audio`, o ejecutar con `sudo`).

---

## Variables de entorno (opcionales, solo `stream-tui.sh`)

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

## `stream-tui.sh` — Transmitir o grabar

### Paso 0 — Modo

Antes de los 5 pasos habituales, el TUI pregunta:

| Opción | Resultado |
|---|---|
| **Transmitir en vivo** | RTMP — YouTube, Facebook, URL personalizada o dual |
| **Grabar localmente** | MP4 en disco, sin transmitir a ningún lado |

El resto de los pasos (cámara, micrófono, bitrate, overlays) son
idénticos en ambos modos; solo cambia el **Paso 3**.

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

### Paso 2 — Micrófono

Detecta micrófonos via `arecord -l`. Si hay más de uno, muestra menú.
La última opción siempre es "Sin audio".

- **Mono** — recomendado para voz (BOYA, micrófono de solapa).
- **Stereo** — para música o cámara con micrófono integrado.

Micrófonos BOYA / Focusrite Scarlett detectan automáticamente 48 000 Hz;
el resto usan 44 100 Hz por defecto.

### Paso 3A — Plataforma y Stream Key (modo "Transmitir en vivo")

| Opción | Destino |
|---|---|
| YouTube Live | `rtmp://a.rtmp.youtube.com/live2/<KEY>` |
| Facebook / Meta Live | `rtmps://live-api-s.facebook.com:443/rtmp/<KEY>` |
| URL personalizada | Cualquier destino RTMP/RTMPS |
| ★ Dual stream | YouTube **y** Facebook simultáneamente _(experimental)_ |

**Dual stream:** usa el muxer `tee` de ffmpeg con `onfail=ignore` — si
una plataforma cae, la otra continúa transmitiendo. Requiere suficiente
ancho de banda de subida para dos streams.

> Para probar a un destino local (RTMP vía mediamtx, o MPEG-TS por
> TCP/UDP) antes de elegir plataforma, usar `preview-tui.sh` — ver más
> abajo.

### Paso 3B — Salida (modo "Grabar localmente")

| Pregunta | Default |
|---|---|
| Directorio de salida | `~/recordings` (se crea si no existe) |
| Nombre del archivo | `rec_<timestamp>.mp4` (se agrega `.mp4` si falta) |
| Duración en segundos | `0` = indefinida (Ctrl+C para detener) |

El resumen final muestra una estimación de espacio en disco (`~X MB`
o `~X MB/min`) calculada con el bitrate elegido en el Paso 4.

La grabación usa el mismo pipeline de `ffmpeg` que el stream en vivo
(mismos overlays, mismo códec), pero con `-movflags +faststart` y
escribe directo al archivo en vez de a una URL RTMP.

### Paso 4 — Bitrate de video

| Opción | Bitrate | Uso recomendado |
|---|---|---|
| Alta calidad | 4 500 kbps | Red rápida, Pi 4B |
| Balance | 2 500 kbps | **Recomendado** |
| Bajo ancho de banda | 1 500 kbps | Red limitada |
| Mínimo | 800 kbps | Conexión muy lenta |

### Paso 5 — Overlays

Ver [Overlays (común a ambos TUIs)](#overlays-común-a-ambos-tuis) más abajo.

### Resumen y confirmación

Antes de lanzar, el TUI muestra un resumen con todos los parámetros
configurados (modo, cámara, audio, destino/salida, overlays) y pide
confirmación (`S/n`).

---

## `preview-tui.sh` — Probar antes de salir en vivo

Mismos pasos 1, 2 y 4 que `stream-tui.sh` (cámara, micrófono, bitrate —
con opciones de bitrate pensadas para preview: 1500/2500/800 kbps), más
el Paso de Overlays (igual al de `stream-tui.sh`). El paso particular
es el de transporte:

### Paso — Transporte

| Transporte | Cómo funciona | Comando para ver en otra máquina |
|---|---|---|
| **TCP** (recomendado) | La Pi escucha en el puerto indicado; VLC conecta cuando quiere | `vlc tcp://<ip-pi>:<puerto>` (abrir **después** de iniciar) |
| **UDP** | La Pi empuja de inmediato al cliente indicado — menor latencia | `vlc udp://@:<puerto>` (abrir **antes** de iniciar, o se pierden los primeros paquetes) |
| **RTMP** | Publica a `rtmp://localhost:1935/<nombre>` vía **mediamtx** — admite varios espectadores a la vez | `vlc rtmp://<ip-pi>:1935/<nombre>` desde cualquier equipo de la LAN, incluso simultáneamente |

RTMP requiere mediamtx corriendo en la Pi:

```bash
sudo ./scripts/mediamtx-install.sh   # una vez
./scripts/control.sh start mediamtx  # cada vez que se necesite
```

Si mediamtx no está escuchando en el puerto 1935, el TUI lo avisa antes
de iniciar (pero no bloquea — el preview fallará al lanzar ffmpeg si
mediamtx no está activo).

Tras elegir transporte, el TUI detecta la IP de la Pi (`hostname -I`) y
muestra el comando VLC exacto a copiar, tanto en el resumen como justo
antes de lanzar.

> **Equivalente en el portal web:** la tarjeta "Vista previa" del
> dashboard (`docs/web-api.md`) ofrece exactamente los mismos tres
> transportes, reutilizando la configuración ya guardada en el
> acordeón — sin necesidad de SSH.

---

## Overlays (común a ambos TUIs)

### Logo PNG

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

### Banner de texto

Barra semitransparente con texto centrado, ubicada en:
- `footer` — barra inferior (default)
- `header` — barra superior

### Fecha y hora actual

Tercera opción del paso de overlays. Usa `drawtext` con
`%{localtime\:%F %T}` — se actualiza en vivo sin reiniciar el stream.
Posición elegible: `tl` (default), `tr`, `bl`, `br`.

Logo, banner y fecha/hora son combinables entre sí en cualquier mezcla
— el motor compartido (`build_overlay_args` en `lib/common.sh`) los
encadena en un único `filter_complex` de ffmpeg sin importar cuántos
estén activos.

---

## Diferencias respecto a `stream-overlay.sh`

`stream-tui.sh` y `preview-tui.sh` son wrappers interactivos. Para el
modo "Transmitir en vivo" sin overlays ni dual stream, `stream-tui.sh`
delega en `scripts/usb-camera.sh` (ruta simple); con overlays o dual
stream construye el comando `ffmpeg` directamente. El modo "Grabar
localmente" siempre construye el comando `ffmpeg` directamente
(escribe a archivo, no hay ruta de delegación).

`stream-overlay.sh`, en cambio, es el script no interactivo que usan
los servicios systemd (`streaming-overlay.service` y `preview.service`)
controlados desde la web API. Acepta todos los parámetros por
argumentos o variables de entorno, sin interacción, e incluye además
`--transport {rtmp,tcp,udp}` para que `preview.service` pueda servir el
mismo preview sin pasar por ningún TUI.

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
# Solo si se va a usar transporte RTMP en preview-tui.sh:
sudo ./scripts/mediamtx-install.sh
```
