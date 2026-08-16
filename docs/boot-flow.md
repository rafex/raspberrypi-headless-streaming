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
/etc/raspi-streaming/backend-control-agent.env
/etc/raspi-streaming/ngrok.env
/etc/raspi-streaming/ngrok.yml
```

Si `/etc/raspi-streaming/boot-flow.env` ya existe, la instalación actualiza
automáticamente solo los antiguos defaults `120` y `420` a `600` segundos.
Otros valores se consideran personalizados y se conservan.

## Auto-stream diferido

Archivo:

```bash
sudo nano /etc/raspi-streaming/boot-flow.env
```

Valores principales:

```env
AUTO_STREAM_ENABLED=false
AUTO_STREAM_DELAY_SECONDS=600
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

### Por qué 600s (10 min) y no menos

Con `AUTO_STREAM_DELAY_SECONDS=120` (2 min) se observaron fallos intermitentes
al primer intento tras reboot: `ffmpeg` reportaba `Device or resource busy` al
abrir `/dev/video0`, porque el driver UVC de la cámara USB y/o el subsistema
V4L2 del kernel todavía no habían terminado de estabilizarse ese poco tiempo
después del arranque. `systemd` reintentaba automáticamente (`Restart=on-failure`,
`RestartSec=10`) y el segundo intento sí funcionaba — pero es un margen
justo, no garantizado, especialmente en un Pi 3B con almacenamiento SD lento.

600s da margen amplio a: WiFi completamente asociado y con IP estable,
módulos de kernel (`bcm2835-codec`, `uvcvideo`) inicializados, y cualquier
`apt`/`fsck`/servicio de arranque tardío del sistema terminado. El costo es
que la transmisión automática tarda unos minutos más en aparecer — aceptable
para un dispositivo que arranca una vez y transmite por horas.

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

`make boot-flow` instala `ngrok` si falta. El authtoken se guarda en el YAML
local de ngrok, no en `ngrok.env`. El archivo puede declarar ambos tuneles:
portal web y SSH.

```yaml
# /etc/raspi-streaming/ngrok.yml
version: 3
agent:
  authtoken: <your-authtoken>

tunnels:
  web:
    proto: http
    addr: https://127.0.0.1:8443
  ssh:
    proto: tcp
    addr: 22
```

Luego ajusta los parametros no secretos del tunel:

```bash
sudo nano /etc/raspi-streaming/ngrok.yml
sudo nano /etc/raspi-streaming/ngrok.env
sudo systemctl enable --now ngrok-web.service
```

Config ejemplo:

```env
NGROK_BIN=ngrok
NGROK_CONFIG=/etc/raspi-streaming/ngrok.yml
NGROK_DOMAIN=
NGROK_LOCAL_URL=https://127.0.0.1:8443
NGROK_EXTRA_ARGS=
```

Si `ngrok.yml` contiene `tunnels:`, `ngrok-web.service` ejecuta
`ngrok start --all`. Para ver el endpoint SSH:

```bash
curl -s http://127.0.0.1:4040/api/tunnels
```

El tunnel SSH aparece como `tcp://HOST:PORT`. La conexion queda:

```bash
ssh root@HOST -p PORT
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
BACKEND_CLIENT_CERT=/etc/raspi-streaming/backend-client/raspi-client.crt
BACKEND_CLIENT_KEY=/etc/raspi-streaming/backend-client/raspi-client.key
HEALTH_INTERVAL_SECONDS=60
```

Activar:

```bash
sudo systemctl enable --now health-reporter.service
```

El payload incluye estado de servicios, IP, SSID, dispositivos, configuración
sin stream keys y URL pública de ngrok si está disponible.

## Control remoto desde backend

El backend publica un `desired-state` para cada Raspi. El agente local hace
polling outbound con el mismo token/certificado que el health reporter, aplica
solo variables permitidas de `/etc/streaming.env` y ejecuta comandos acotados
como `start_streaming_overlay`, `stop_all` o `apply_config`.

```bash
sudo nano /etc/raspi-streaming/backend-control-agent.env
sudo systemctl enable --now backend-control-agent.service
```

Config ejemplo:

```env
BACKEND_BASE_URL=https://streaming.rafex.io
BACKEND_DEVICE_ID=raspi3b
BACKEND_TOKEN=
BACKEND_CLIENT_CERT=/etc/raspi-streaming/backend-client/raspi-client.crt
BACKEND_CLIENT_KEY=/etc/raspi-streaming/backend-client/raspi-client.key
BACKEND_AGENT_INTERVAL_SECONDS=30
STREAMING_ENV=/etc/streaming.env
```

No envía `STREAM_KEY`, `STREAM_KEY_META`, `RTMP_URL` ni `RTMP_URL_SECONDARY`.
