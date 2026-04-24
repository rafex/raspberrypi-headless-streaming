# PLAN.md

## Objetivo

Construir un sistema completo de captura y streaming headless para Raspberry Pi.  
El sistema debe funcionar desde línea de comandos sin interfaz gráfica, usando hardware H264 de la Pi y herramientas open source disponibles en repositorios Debian/DietPi.

---

## Fases

### Fase 1 — Fundación y captura básica

**Meta:** captura de video funcional desde terminal.

Tareas:

- [x] Crear estructura de directorios del repositorio (`scripts/`, `assets/`, `systemd/`, `docs/`)
- [x] Documentar instalación de dependencias (`libcamera-apps`, `ffmpeg`)
- [x] Activar cámara en DietPi (`dietpi-config → Advanced Options → Camera`)
- [x] Script `scripts/capture.sh` — captura local a archivo `.h264`
- [x] Verificar encoding H264 por hardware (no software)
- [x] Documentar limitaciones Pi 3B (1080p30, ~4–5 Mbps)

Entregable: `scripts/capture.sh` funcional, video `.h264` grabado en Pi.

---

### Fase 2 — Streaming RTMP básico

**Meta:** transmisión en vivo sin overlays desde la Pi.

Tareas:

- [x] Script `scripts/stream.sh` — pipeline `libcamera-vid | ffmpeg → RTMP`
- [x] Parametrizar RTMP endpoint y stream key via variables de entorno o argumentos
- [x] Probar con YouTube Live (`rtmp://a.rtmp.youtube.com/live2/<KEY>`)
- [x] Probar con servidor RTMP local (nginx-rtmp o mediamtx)
- [x] Documentar parámetros de bitrate y framerate recomendados para Pi 3B

Entregable: `scripts/stream.sh` funcional, stream en vivo verificado.

---

### Fase 3 — Overlays y procesamiento de video

**Meta:** aplicar logos, marcos y texto sobre el stream.

Tareas:

- [x] Agregar assets de ejemplo (`assets/logo.png`, `assets/frame.png`)
- [x] Script `scripts/stream-overlay.sh` — stream con overlay de logo PNG
- [x] Implementar overlay de marco PNG (fullscreen frame sobre video)
- [x] Implementar overlay de texto estático (`drawtext`)
- [x] Implementar overlay de timestamp dinámico
- [x] Medir impacto en CPU al aplicar overlays (Pi 3B requiere re-encoding)
- [x] Documentar combinaciones de overlays recomendadas vs limitaciones

Entregable: `scripts/stream-overlay.sh` con parámetros configurables.

---

### Fase 4 — Grabación simultánea

**Meta:** grabar y transmitir al mismo tiempo.

Tareas:

- [x] Script `scripts/record.sh` — grabación local sin streaming
- [x] Script `scripts/stream-record.sh` — pipeline con `tee` para grabación + streaming simultáneo
- [x] Verificar que no hay degradación de calidad en modo dual
- [x] Documentar uso de disco estimado (1080p30 H264 ~4–5 Mbps ≈ ~36 MB/min)

Entregable: `scripts/stream-record.sh` funcional.

---

### Fase 5 — Automatización con systemd

**Meta:** stream que arranca automáticamente y se recupera de fallos.

Tareas:

- [x] Crear `systemd/streaming.service` con `Restart=on-failure`
- [x] Documentar instalación del servicio (`systemctl enable`)
- [x] Probar reinicio automático al desconectar/reconectar cámara
- [x] Agregar logging a journald
- [x] Script de control `scripts/control.sh` (start / stop / status / restart)

Entregable: servicio systemd funcional, stream arranca en boot.

---

### Fase 6 — Modo RTSP (servidor local)

**Meta:** exponer el stream via RTSP para consumo interno (red local, otros dispositivos).

Tareas:

- [x] Documentar instalación de mediamtx
- [x] Script `scripts/stream-rtsp.sh` — pipeline hacia servidor RTSP local
- [x] Verificar acceso desde otro dispositivo en la misma red (`rtsp://raspi:8554/cam`)
- [x] Documentar caso de uso: Pi 3B → RTSP → Pi 4B (o cualquier cliente)

Entregable: stream RTSP consumible desde red local.

---

### Fase 7 — Detección de movimiento y eventos

**Meta:** streaming event-based, no continuo.

Tareas:

- [x] Evaluar opciones: `motion`, frame diff con ffmpeg, OpenCV
- [x] Script `scripts/motion-trigger.sh` — activa stream al detectar movimiento
- [x] Implementar ventana de cooldown (evitar activaciones repetidas)
- [x] Enviar notificación de evento (webhook o log estructurado)
- [x] Documentar umbrales recomendados para Pi 3B

Entregable: script de stream activado por movimiento.

---

### Fase 8 — Integración con análisis de IA (extensión)

**Meta:** enviar frames o eventos al LLM para análisis (arquitectura Pi 3B → Pi 4B).

Tareas:

- [x] Script `scripts/frame-extract.sh` — extraer frame JPEG del stream cada N segundos
- [x] Script `scripts/send-event.sh` — enviar evento o frame a endpoint HTTP (Pi 4B)
- [x] Documentar API mínima esperada en Pi 4B para recibir frames
- [x] Integrar con detección de movimiento (evento → frame → LLM)
- [x] Documentar arquitectura completa: red + video + IA

Entregable: pipeline completo detección de movimiento → frame → análisis LLM.

---

### Fase 9 — Servidor de análisis IA con DeepSeek y OpenRouter

**Meta:** servidor HTTP listo para producción en Pi 4B que acepta frames y eventos, y los analiza con DeepSeek o OpenRouter según configuración.

Tareas:

- [x] Crear `server/analyze-server.py` — servidor Flask con soporte de múltiples proveedores
- [x] Implementar proveedor DeepSeek (API OpenAI-compatible, modelos con visión)
- [x] Implementar proveedor OpenRouter (acceso a modelos de visión de terceros)
- [x] Permitir selección de proveedor y modelo via variable de entorno o argumento
- [x] Crear `server/requirements.txt` con dependencias mínimas
- [x] Crear `scripts/ai-server-install.sh` — instalación automatizada en Pi 4B
- [x] Crear `systemd/ai-server.service` — servicio systemd para el servidor
- [x] Documentar modelos recomendados para cada proveedor

Entregable: servidor funcional en Pi 4B seleccionando proveedor con `AI_PROVIDER=deepseek|openrouter`.

---

## Estructura final del repositorio

```
raspberrypi-headless-streaming/
├── AGENTS.md
├── PLAN.md
├── README.md
├── LICENSE
├── scripts/
│   ├── capture.sh          # grabación local
│   ├── stream.sh           # streaming RTMP básico
│   ├── stream-overlay.sh   # streaming con overlays
│   ├── stream-record.sh    # grabación + streaming simultáneo
│   ├── stream-rtsp.sh      # streaming hacia servidor RTSP
│   ├── record.sh           # grabación sin streaming
│   ├── motion-trigger.sh   # stream activado por movimiento
│   ├── frame-extract.sh    # extracción de frames para IA
│   ├── send-event.sh       # envío de eventos a endpoint HTTP
│   └── control.sh          # control del servicio (start/stop/status)
├── assets/
│   ├── logo.png
│   └── frame.png
├── systemd/
│   └── streaming.service
└── docs/
    ├── setup.md            # instalación y configuración inicial
    ├── architecture.md     # diagrama de arquitectura del sistema
    ├── overlays.md         # referencia de filtros y overlays ffmpeg
    └── ai-integration.md  # integración con LLM en Pi 4B
```

---

## Dependencias

| Herramienta | Instalación | Propósito |
|---|---|---|
| `libcamera-apps` | `apt install libcamera-apps` | captura de cámara |
| `ffmpeg` | `apt install ffmpeg` | processing, overlays, streaming |
| `mediamtx` | descarga desde GitHub releases | servidor RTSP |
| `motion` | `apt install motion` | detección de movimiento (opcional) |

---

## Restricciones de hardware (Pi 3B)

- Resolución máxima estable: 1080p
- FPS máximo: 30
- Bitrate recomendado: 4–5 Mbps
- Overlays incrementan uso de CPU (re-encoding en software)
- Evitar más de 2 filtros ffmpeg simultáneos
- CPU libre esperado con stream básico: ~40–60%

---

## Prioridad de implementación

```
Fase 1 → Fase 2 → Fase 3 → Fase 4 → Fase 5
                                         ↓
                                      Fase 6
                                         ↓
                                      Fase 7
                                         ↓
                                      Fase 8
                                         ↓
                                      Fase 9
```

Las fases 1–5 son el núcleo funcional.  
Las fases 6–8 son extensiones para casos de uso avanzados.  
La fase 9 es el servidor de análisis de IA con proveedores configurables.
