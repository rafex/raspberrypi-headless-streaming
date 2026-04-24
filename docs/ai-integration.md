# Integración con IA

Documentación del pipeline completo: Pi 3B (cámara + red) → Pi 4B (LLM + análisis).

---

## Arquitectura completa

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Raspberry Pi 3B                               │
│                                                                        │
│  ┌──────────────┐   frame-diff   ┌──────────────────────────────┐    │
│  │ libcamera    │───────────────▶│     ai-pipeline.sh           │    │
│  │ 320x240      │  (cada 2s)     │                              │    │
│  │ detección    │                │  movimiento detectado?       │    │
│  └──────────────┘                │    ├─ captura frame 1280x720 │    │
│                                  │    ├─ POST /analyze → Pi 4B  │    │
│  ┌──────────────┐                │    └─ activa stream RTSP     │    │
│  │ libcamera    │◀───────────────│                              │    │
│  │ 1920x1080    │  stream activo │  sin movimiento 30s?        │    │
│  │ H264 HW      │                │    └─ detiene stream        │    │
│  └──────┬───────┘                └──────────────────────────────┘    │
│         │                                        │                    │
│  ┌──────▼───────┐                               │ HTTP POST          │
│  │  mediamtx    │                               │ frame JPEG b64     │
│  │  RTSP :8554  │                               │                    │
│  └──────┬───────┘                               │                    │
│         │                                        │                    │
│  sensor de red ──────────────────────────────────┼──────────────────▶│
│  (eventos de red)                     websocket/HTTP                  │
└─────────────────────────────────────────────────┼────────────────────┘
                                                   │
                                    red local (LAN / Wi-Fi)
                                                   │
┌──────────────────────────────────────────────────▼────────────────────┐
│                         Raspberry Pi 4B                                │
│                                                                         │
│  ┌─────────────────────────────────────────────────────────────────┐   │
│  │  Servidor HTTP /analyze                                          │   │
│  │                                                                  │   │
│  │  POST /analyze                                                   │   │
│  │  {                                                               │   │
│  │    "event": "motion_analysis",                                   │   │
│  │    "source": "raspi-3b",                                         │   │
│  │    "context": "Movimiento detectado (score: 0.23)",              │   │
│  │    "frame": "<base64 JPEG>"                                      │   │
│  │  }                                                               │   │
│  │         │                                                        │   │
│  │         ▼                                                        │   │
│  │  LLM con visión (Claude / LLaVA / Ollama)                       │   │
│  │         │                                                        │   │
│  │         ▼                                                        │   │
│  │  {                                                               │   │
│  │    "analysis": "Se detecta una persona en el pasillo.",          │   │
│  │    "confidence": 0.91,                                           │   │
│  │    "tags": ["person", "indoor", "motion"]                        │   │
│  │  }                                                               │   │
│  └─────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌─────────────┐    ┌─────────────┐    ┌──────────────────────────┐   │
│  │ ffmpeg RTSP │    │  portal web │    │  eventos de red (Pi 3B)  │   │
│  │ consume     │    │  dashboard  │    │  sensor integrado        │   │
│  │ stream cam  │    │             │    │                          │   │
│  └─────────────┘    └─────────────┘    └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## API esperada en Pi 4B

El servidor en Pi 4B debe exponer un endpoint HTTP que acepte frames y eventos.

### POST /analyze

**Request:**

```json
{
  "event": "motion_analysis",
  "source": "raspi-3b",
  "timestamp": "2024-01-01T12:00:00+00:00",
  "context": "Movimiento detectado (score: 0.23)",
  "frame": "<base64 del JPEG 1280x720>"
}
```

**Response:**

```json
{
  "analysis": "Se detecta una persona entrando por la puerta izquierda.",
  "confidence": 0.91,
  "tags": ["person", "indoor", "motion"]
}
```

### POST /event (solo texto, sin frame)

```json
{
  "event": "motion_start",
  "source": "raspi-3b",
  "timestamp": "2024-01-01T12:00:00+00:00",
  "context": ""
}
```

---

## Ejemplo mínimo de servidor en Pi 4B (Python)

```python
from flask import Flask, request, jsonify
import anthropic
import base64

app = Flask(__name__)
client = anthropic.Anthropic()

@app.route("/analyze", methods=["POST"])
def analyze():
    data = request.json
    frame_b64 = data.get("frame", "")
    context = data.get("context", "")
    source = data.get("source", "unknown")

    if not frame_b64:
        return jsonify({"analysis": "Sin frame", "confidence": 0})

    message = client.messages.create(
        model="claude-opus-4-7",
        max_tokens=256,
        messages=[
            {
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": frame_b64,
                        },
                    },
                    {
                        "type": "text",
                        "text": (
                            f"Fuente: {source}. Contexto: {context}. "
                            "Describe brevemente qué se ve en la imagen. "
                            "Indica si hay personas, objetos, o situaciones relevantes."
                        )
                    }
                ],
            }
        ],
    )

    analysis = message.content[0].text
    return jsonify({
        "analysis": analysis,
        "confidence": 0.9,
        "tags": []
    })

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
```

Instalar dependencias en Pi 4B:

```bash
pip install flask anthropic
ANTHROPIC_API_KEY=sk-... python server.py
```

---

## Scripts disponibles

### ai-pipeline.sh — orquestador completo

Combina detección + stream + análisis LLM en un único proceso:

```bash
# Detección y análisis, sin stream
./scripts/ai-pipeline.sh --ai-host 192.168.1.100

# Con stream RTSP simultáneo
./scripts/ai-pipeline.sh \
    --ai-host 192.168.1.100 \
    --stream \
    --threshold 0.10 \
    --cooldown 20 \
    --stop-after 60
```

### frame-extract.sh + send-event.sh — modular

Para casos donde se quiere extracción periódica independiente del movimiento:

```bash
# Extraer un frame cada 10s y enviarlo al LLM
./scripts/frame-extract.sh \
    --interval 10 \
    --on-frame "scripts/send-event.sh --frame \"\$1\" --host 192.168.1.100"

# Extraer desde stream RTSP (si ya está corriendo)
./scripts/frame-extract.sh \
    --rtsp rtsp://localhost:8554/cam \
    --interval 5 \
    --on-frame "scripts/send-event.sh --frame \"\$1\" --host 192.168.1.100"
```

### send-event.sh — notificaciones de texto

```bash
# Notificar inicio de movimiento
./scripts/send-event.sh \
    --event motion_start \
    --host 192.168.1.100 \
    --context "3 dispositivos nuevos en red"

# Enviar frame puntual
./scripts/send-event.sh \
    --frame /tmp/frames/frame_latest.jpg \
    --host 192.168.1.100 \
    --verbose
```

---

## Combinación con sensor de red

El evento más potente para la demo es correlacionar red + video:

```bash
# Cuando el sensor detecta un dispositivo nuevo en la red, enviar frame al LLM
# Esto se integra en el script del sensor de red de Pi 3B:

on_new_device() {
    local mac="$1"
    local ip="$2"

    # Capturar frame en ese momento
    libcamera-jpeg --width 1280 --height 720 \
        --nopreview --timeout 500 \
        --output /tmp/event_frame.jpg 2>/dev/null

    # Enviar al LLM con contexto de red
    scripts/send-event.sh \
        --frame /tmp/event_frame.jpg \
        --event network_device_detected \
        --context "Nuevo dispositivo: MAC=${mac} IP=${ip}" \
        --host 192.168.1.PI4B
}
```

La respuesta del LLM puede ser:

```
[LLM] Se detecta una persona sentándose frente a un portátil.
      Coincide temporalmente con la conexión de un nuevo dispositivo Wi-Fi.
      Posible punto de acceso falso o dispositivo no autorizado.
```

---

## Parámetros recomendados para Pi 3B

| Parámetro | Valor | Motivo |
|---|---|---|
| `--threshold` | 0.15 | balance sensibilidad / falsos positivos |
| `--interval` | 2s | un análisis cada 2s no satura la CPU |
| `--cooldown` | 15–30s | evitar saturar el LLM con frames duplicados |
| `--frame-width` | 1280 | suficiente para visión del LLM |
| `--frame-quality` | 85 | balance tamaño / calidad |
| Frame tamaño aprox | ~80–120 KB | aceptable para envío HTTP local |
| Latencia análisis | 2–5s | Claude API en red local vía Pi 4B |

---

## Systemd para el pipeline completo

Para ejecutar `ai-pipeline.sh` como servicio:

```bash
# Copiar y adaptar el servicio de motion-trigger
sudo cp systemd/motion-trigger.service /etc/systemd/system/ai-pipeline.service
sudo nano /etc/systemd/system/ai-pipeline.service
# Cambiar ExecStart a scripts/ai-pipeline.sh con los parámetros correctos

sudo systemctl daemon-reload
sudo systemctl enable ai-pipeline
sudo systemctl start ai-pipeline
```

Ver logs:

```bash
journalctl -u ai-pipeline -f
```
