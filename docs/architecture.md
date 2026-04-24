# Arquitectura del sistema

Descripción del pipeline de captura y streaming headless en Raspberry Pi.

---

## Pipeline básico (Fase 2)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Raspberry Pi 3B / 4B                      │
│                                                                   │
│  ┌─────────────┐    ┌──────────────────┐    ┌────────────────┐  │
│  │   Cámara    │───▶│  libcamera-vid   │───▶│     ffmpeg     │  │
│  │  (CSI/USB)  │    │ encoder H264 HW  │    │  empaquetado   │  │
│  └─────────────┘    └──────────────────┘    └───────┬────────┘  │
│                            stdout pipe               │           │
└──────────────────────────────────────────────────────┼───────────┘
                                                        │
                                                    RTMP/FLV
                                                        │
                                           ┌────────────▼────────────┐
                                           │    Servidor RTMP         │
                                           │  YouTube / Facebook /    │
                                           │  nginx-rtmp / mediamtx  │
                                           └─────────────────────────┘
```

### Flujo de datos

1. La cámara envía frames en crudo al procesador de imagen (ISP)
2. `libcamera-vid` captura y codifica en H264 usando el bloque de hardware Video Core IV
3. El stream H264 se envía por stdout via pipe Unix al proceso `ffmpeg`
4. `ffmpeg` envuelve el stream en contenedor FLV y lo transmite por RTMP

### Por qué este diseño

- El encoding ocurre en hardware: la CPU queda libre para otros procesos
- El pipe Unix entre procesos es eficiente y no requiere archivos temporales
- `ffmpeg` maneja la negociación RTMP y el reempaquetado sin re-codificar

---

## Pipeline con overlays (Fase 3)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Raspberry Pi 3B / 4B                      │
│                                                                   │
│  ┌─────────────┐    ┌──────────────────┐    ┌────────────────┐  │
│  │   Cámara    │───▶│  libcamera-vid   │───▶│     ffmpeg     │  │
│  │  (CSI/USB)  │    │ encoder H264 HW  │    │ decode + filter│  │
│  └─────────────┘    └──────────────────┘    │ + re-encode    │  │
│                                              │ + overlay PNG  │  │
│  ┌─────────────┐                            └───────┬────────┘  │
│  │  assets/    │───────────────────────────────────▶│           │
│  │  logo.png   │                                    │           │
│  └─────────────┘                                    │           │
└─────────────────────────────────────────────────────┼───────────┘
                                                       │
                                                   RTMP/FLV
                                                       │
                                          ┌────────────▼────────────┐
                                          │    Servidor RTMP         │
                                          └─────────────────────────┘
```

**Nota:** Los overlays requieren decode + re-encode en CPU (no hardware).  
Esto incrementa el uso de CPU en la Pi 3B. Ver [limitaciones](#limitaciones).

---

## Pipeline dual: grabación + streaming (Fase 4)

```
┌─────────────────────────────────────────────────────────────────┐
│                        Raspberry Pi 3B / 4B                      │
│                                                                   │
│  ┌─────────────┐    ┌──────────────────┐    ┌────────────────┐  │
│  │   Cámara    │───▶│  libcamera-vid   │───▶│      tee       │  │
│  │  (CSI/USB)  │    │ encoder H264 HW  │    └───────┬────────┘  │
│  └─────────────┘    └──────────────────┘            │           │
│                                               ┌──────┴──────┐    │
│                                               │             │    │
│                                     ┌─────────▼──┐  ┌──────▼──┐ │
│                                     │  archivo   │  │  ffmpeg │ │
│                                     │  .h264     │  │  RTMP   │ │
│                                     └────────────┘  └─────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

El comando `tee` duplica el stream H264 sin overhead adicional de CPU.

---

## Arquitectura extendida: Pi 3B → Pi 4B con IA (Fase 8)

```
┌────────────────────────────┐        ┌────────────────────────────┐
│      Raspberry Pi 3B       │        │      Raspberry Pi 4B       │
│                            │        │                            │
│  cámara                    │        │  LLM (análisis)            │
│    │                       │        │    ▲                       │
│  libcamera-vid             │  RTSP  │    │                       │
│    │                       │───────▶│  ffmpeg                   │
│  ffmpeg                    │        │  extrae frames             │
│    │                       │        │    │                       │
│  mediamtx (RTSP server)    │        │  POST /analyze             │
│                            │        │  (API HTTP)                │
│  sensor de red             │        │    │                       │
│    │                       │        │  respuesta LLM             │
│  eventos red               │───────▶│    │                       │
│  (webhook/socket)          │        │  portal web                │
└────────────────────────────┘        └────────────────────────────┘
```

### Flujo de eventos combinado

```
Pi 3B detecta movimiento
        │
        ├─ activa stream RTSP
        │
        └─ envía evento HTTP a Pi 4B
                │
                ▼
        Pi 4B extrae frame del stream RTSP
                │
                ▼
        LLM analiza frame + contexto de red
                │
                ▼
        Respuesta: "Movimiento detectado + 3 dispositivos nuevos en red"
```

---

## Comandos clave del pipeline

### Stream básico sin overlays

```bash
libcamera-vid -t 0 \
  --width 1920 --height 1080 \
  --framerate 30 --codec h264 \
  --inline --output - \
| ffmpeg -re -i - \
  -vcodec copy -f flv rtmp://servidor/live/key
```

### Stream con overlay de logo

```bash
libcamera-vid -t 0 \
  --width 1920 --height 1080 \
  --framerate 30 --codec h264 \
  --inline --output - \
| ffmpeg -re -i - \
  -i assets/logo.png \
  -filter_complex "overlay=W-w-20:H-h-20" \
  -vcodec libx264 -preset veryfast \
  -f flv rtmp://servidor/live/key
```

### Grabación + streaming simultáneo

```bash
libcamera-vid -t 0 \
  --width 1920 --height 1080 \
  --framerate 30 --codec h264 \
  --inline --output - \
| tee capture.h264 \
| ffmpeg -re -i - \
  -vcodec copy -f flv rtmp://servidor/live/key
```

---

## Limitaciones

### Raspberry Pi 3B

| Parámetro | Límite | Motivo |
|---|---|---|
| Resolución máxima | 1080p | encoder hardware |
| FPS máximo estable | 30 | ancho de banda del CSI |
| Re-encoding con overlays | posible, lento | CPU limitada (~4 cores A53 1.2GHz) |
| Filtros ffmpeg simultáneos | 1–2 max | cada filtro consume CPU |
| Bitrate recomendado | 4–5 Mbps | balance calidad/CPU |

### Raspberry Pi 4B

| Parámetro | Límite | Motivo |
|---|---|---|
| Resolución máxima | 1080p60 / 4K30 | encoder V4L2 H265 disponible |
| Re-encoding con overlays | fluido | CPU más potente (~4 cores A72 1.8GHz) |
| Bitrate | hasta 25 Mbps estable | —  |

---

## Plataformas RTMP soportadas

| Plataforma | URL RTMP | Notas |
|---|---|---|
| YouTube Live | `rtmp://a.rtmp.youtube.com/live2/<KEY>` | requiere cuenta verificada |
| Facebook Live | `rtmps://live-api-s.facebook.com:443/rtmp/<KEY>` | RTMPS (TLS) |
| Servidor local nginx-rtmp | `rtmp://localhost/live/<nombre>` | requiere módulo nginx-rtmp |
| mediamtx (RTSP/RTMP) | `rtmp://localhost:1935/live/<nombre>` | recomendado para red local |
