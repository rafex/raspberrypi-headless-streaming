# Flujo de arranque, acceso remoto y reporte de salud

Este flujo separa conectividad, portal y transmisión:

1. `raspi-wifi-bootstrap.service` intenta las redes WiFi preconfiguradas.
2. Si ninguna conecta, entra en hotspot/AP de configuración.
3. Si conecta a una WiFi, levanta portal/servicios.
4. `boot-stream-orchestrator.service` espera servicios + delay y solo inicia streaming si está habilitado explícitamente.
5. Antes de transmitir selecciona audio base: BOYA primero, webcam después, primer USB después; si no hay micrófono usa silencio AAC.
6. `ngrok-web.service` puede publicar el portal.
7. `health-reporter.service` puede mandar estado a un endpoint público.

## Instalación

```bash
make boot-flow
```

Crea, si no existen:

```text
/etc/raspi-streaming/boot-flow.env
/etc/raspi-streaming/health-reporter.env
/etc/raspi-streaming/ngrok.env
```

## Auto-stream diferido

Archivo:

```bash
sudo nano /etc/raspi-streaming/boot-flow.env
```

Valores principales:

```env
AUTO_STREAM_ENABLED=false
AUTO_STREAM_DELAY_SECONDS=120
AUTO_STREAM_SERVICE=streaming-overlay.service
AUTO_STREAM_WAIT_SERVICES="web-api.service ngrok-web.service health-reporter.service"
AUTO_STREAM_REQUIRE_DEFAULT_ROUTE=true
AUTO_STREAM_AUDIO_CHANNELS=1
```

Para habilitar:

```env
AUTO_STREAM_ENABLED=true
```

El servicio no inicia streaming en modo AP porque exige ruta default. Si
`RTMP_URL` está vacío en `/etc/streaming.env`, tampoco arranca.

## Audio base automático

Antes de iniciar stream automático:

```bash
scripts/stream-audio-autoconfig.py --env /etc/streaming.env
```

Prioridad:

1. BOYA / BOYALINK
2. micrófono de webcam
3. primer micrófono USB
4. silencio AAC (`STREAM_NO_AUDIO=true`)

El portal puede seguir cambiando la configuración como antes.

## ngrok

Instala y autentica `ngrok` fuera del repo. Luego:

```bash
sudo nano /etc/raspi-streaming/ngrok.env
sudo systemctl enable --now ngrok-web.service
```

Config ejemplo:

```env
NGROK_BIN=ngrok
NGROK_DOMAIN=
NGROK_LOCAL_URL=https://127.0.0.1:8443
NGROK_EXTRA_ARGS=
```

El reporter lee la URL pública desde la API local de ngrok:

```text
http://127.0.0.1:4040/api/tunnels
```

## Health reporter

Archivo:

```bash
sudo nano /etc/raspi-streaming/health-reporter.env
```

Config:

```env
HEALTH_ENDPOINT=https://tu-endpoint-publico.example/raspi/health
HEALTH_TOKEN=
HEALTH_INTERVAL_SECONDS=60
```

Activar:

```bash
sudo systemctl enable --now health-reporter.service
```

El payload incluye estado de servicios, IP, SSID, dispositivos, configuración
sin stream keys y URL pública de ngrok si está disponible.

No envía `STREAM_KEY`, `STREAM_KEY_META`, `RTMP_URL` ni `RTMP_URL_SECONDARY`.
