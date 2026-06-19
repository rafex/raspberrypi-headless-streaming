# Web API: control de la transmisión desde el celular

API REST + frontend ligero, servidos por el mismo proceso (gunicorn + Flask)
sobre HTTPS con certificado autofirmado, que permite encender/apagar la
transmisión y configurarla sin entrar por SSH. Corre en la Pi 3B (o 4B),
junto a los servicios `streaming` / `streaming-overlay` que maneja
`stream-overlay.sh`.

---

## Componentes

| Pieza | Rol |
|---|---|
| `server/webapi/app.py` | API REST + sirve el frontend estático |
| `server/webapi/secrets_store.py` | descifra usuarios con `sops`+`age` en memoria |
| `server/webapi/auth.py` | login por sesión (cookie), CSRF, roles |
| `server/webapi/stream_control.py` | `systemctl start/stop/is-active` de los dos servicios |
| `server/webapi/config_store.py` | lee/escribe `/etc/streaming.env` |
| `server/webapi/static/` | frontend (HTML/CSS/JS vanilla, sin build) |
| `scripts/manage-users.sh` | alta/baja/listado de usuarios cifrados |
| `scripts/web-api-install.sh` | instala venv (con `uv`), TLS, sudoers, systemd unit |

### Roles

- **viewer**: ve el estado de los servicios y la configuración (con el
  destino RTMP enmascarado).
- **operator**: puede iniciar/detener la transmisión y editar toda la
  configuración (destino RTMP completo, overlays, audio, etc.).

### Seguridad

- Las contraseñas se guardan hasheadas (PBKDF2-SHA256) dentro de un YAML
  cifrado con `sops`+`age` — nunca en texto plano, ni en el repo ni en disco.
- La age key privada solo vive en la Pi (`/etc/raspi-streaming/age/key.txt`,
  permisos 600), nunca se versiona.
- El servicio corre como un usuario de sistema sin privilegios (`webapi`),
  con permiso `sudo` acotado únicamente a `systemctl start|stop|is-active` de
  `streaming.service` y `streaming-overlay.service`.
- HTTPS con certificado autofirmado: el navegador del celular mostrará un
  aviso de seguridad la primera vez; hay que aceptarlo explícitamente.
- CSRF token via cabecera `X-CSRF-Token`; `secrets.compare_digest` para
  la comparación. Cookies: Secure=True, HttpOnly=True, SameSite=Strict, 12h.

---

## Instalación paso a paso

Todo el flujo de instalación corre con `make`, en este orden (o de una sola
vez con `make setup`):

### 1. Instalar dependencias

```bash
make deps-web-api
```

Corre `sudo scripts/install-deps.sh --web-api`, que instala `age`, `sops`,
`uv`, `openssl` y `python3-yaml`. Si `sops` no está en `apt` para tu versión
de Debian, instalarlo manualmente desde
[https://github.com/getsops/sops/releases](https://github.com/getsops/sops/releases).

### 2. Generar la age key y configurar `.sops.yaml`

```bash
make age-key
```

Genera (si no existe) `/etc/raspi-streaming/age/key.txt` y reemplaza el
placeholder de `.sops.yaml` con la public key — no hace falta editar nada a mano.

### 3. Crear el primer usuario

```bash
make add-user WEBAPI_USER=admin WEBAPI_ROLE=operator
```

Pide la contraseña en terminal (oculta) y crea `server/webapi/secrets.enc.yaml`
cifrado. Para agregar un viewer:

```bash
make add-user WEBAPI_USER=invitado WEBAPI_ROLE=viewer
```

Para administrar usuarios directamente (listar, quitar):

```bash
SOPS_AGE_KEY_FILE=/etc/raspi-streaming/age/key.txt scripts/manage-users.sh list
SOPS_AGE_KEY_FILE=/etc/raspi-streaming/age/key.txt scripts/manage-users.sh remove invitado
```

### 4. Instalar y habilitar en boot

```bash
make web-api
```

Crea el usuario de sistema `webapi`, el venv en `/opt/web-api/venv` (con `uv`),
el certificado TLS autofirmado, `/etc/web-api.env` con un `SECRET_KEY` aleatorio
y el sudoers acotado; luego activa `web-api.service`.

Equivale a:

```bash
make install-web-api   # sudo scripts/web-api-install.sh
make enable-web-api    # sudo systemctl enable --now web-api.service
```

Otros atajos: `make status-web-api`, `make logs-web-api`, `make restart-web-api`,
`make stop-web-api`, `make disable-web-api` (`make help` lista todos).

### 5. Acceder desde el celular o navegador

```
https://<ip-de-la-pi>:8443
```

El navegador mostrará un aviso de certificado no confiable (es autofirmado):
aceptar y continuar. Iniciar sesión con el usuario creado en el paso 3.

---

## Actualizar después de un `git pull`

Cuando solo cambian archivos de `server/webapi/` (Python + HTML/CSS/JS):

```bash
make deploy-web-api
```

Cuando cambian unit files de systemd (`systemd/*.service`):

```bash
make update-services
```

Ambos cambios a la vez:

```bash
make deploy-web-api && make update-services
```

---

## Interfaz de usuario: acordeón de 5 pasos

El frontend está organizado como un asistente de 5 secciones colapsables,
con paridad de funcionalidad respecto al TUI `stream-tui.sh`:

### Paso 1 — Cámara

- Botón **Escanear** que detecta cámaras y micrófonos vía `/api/devices`.
- Selector de dispositivo de video (auto-detectar o específico `/dev/videoN`).
- Grid 2×2 de resoluciones con descripción:

| Botón | Resolución | Descripción |
|---|---|---|
| 360p | 640×360 @ 30fps | mínimo uso de CPU |
| 480p | 854×480 @ 30fps | menor CPU |
| 720p | 1280×720 @ 30fps | HD — recomendado Pi 3B |
| 1080p | 1920×1080 @ 30fps | Full HD |

- Sección **Personalizado** (colapsable): ancho, alto y FPS libres.

### Paso 2 — Audio

- Selector de micrófono (auto-detectar, dispositivo específico `plughw:N,M`,
  o **Sin audio** → genera silencio AAC para que YouTube no rechace el stream).
- Toggle **Stereo** / Mono.
- Selector de **Sample rate**: 44 100 Hz / 48 000 Hz.
  - Si el micrófono detectado contiene "BOYA", "Focusrite" o "Scarlett",
    se auto-selecciona 48 000 Hz y se muestra un hint.
- Toggle **Boost de audio ×2**: aplica `aresample=async=1,volume=2.0` al
  pipeline de audio — útil para micrófonos de solapa con nivel bajo.

### Paso 3 — Destino

| Opción | Destino |
|---|---|
| YouTube Live | `rtmp://a.rtmp.youtube.com/live2/<KEY>` |
| Facebook / Meta Live | `rtmps://live-api-s.facebook.com:443/rtmp/<KEY>` |
| ★ Dual — YouTube + Facebook | Ambas simultáneamente con `tee` muxer _(experimental)_ |
| URL personalizada | Cualquier destino `rtmp://` o `rtmps://` |

En modo **Dual** se muestran dos campos de stream key (YouTube + Facebook).
Con `onfail=ignore`, si una plataforma falla la otra sigue transmitiendo.

### Paso 4 — Video

Cards 2×2 de calidad de video (igual que el TUI):

| Card | Bitrate | Uso recomendado |
|---|---|---|
| Alta calidad | 4 500 kbps | buena subida · 1080p |
| Balance | 2 500 kbps | recomendado · 720p |
| Bajo ancho | 1 500 kbps | 480p |
| Mínimo | 800 kbps | 360p · menor CPU |

- Sección **Avanzado** (colapsable): bitrate personalizado en bps y preset
  de codificación libx264 (`ultrafast`…`fast`).

### Paso 5 — Overlays

#### Logo PNG

- Ruta local en el sistema de la Pi **o** botón 📁 para subir un archivo
  PNG/JPG desde el navegador (máx. 5 MB → `/var/lib/raspi-streaming/assets/logos/`).
- **Ancho del logo** — chip row con opciones directas: Original / 80 / 100 /
  120 / 150 / 200 px, más campo libre para valores personalizados.
  - Referencia de tamaños según resolución:
    - 360p/480p → 60–80 px · 720p → 100–150 px · 1080p → 120–200 px
- **Posición** — grid visual 2×2 con flechas (↖ ↗ ↙ ↘).
- **Margen** — chip row: 10 / 20 / 30 / 40 / 50 px, más campo libre.

#### Banner (barra + texto centrado)

Barra negra semitransparente (46 px, 72 % opacidad) con texto blanco centrado,
implementada con `drawbox + drawtext` en ffmpeg.

- Campo de texto libre (máx. 200 caracteres).
- Toggle de posición: **▼ Inferior (footer)** / **▲ Superior (header)**.

#### Texto libre (esquina)

Texto con caja de fondo en la posición elegida.

- Grid visual 3×3 con flechas ↖ ↗ ↙ ↘ y ⊙ centro.

#### Timestamp en tiempo real

Toggle que activa `drawtext` con `%{localtime\:%F %T}` en la esquina superior
izquierda.

---

## Iniciar / detener el stream

En la tarjeta principal (sobre el acordeón) hay:

- **Badge** de estado: "Activo — running" / "Detenido — detenido".
- **Toggle "Con overlay"**: determina qué servicio se inicia:
  - ON → `streaming-overlay.service` (re-encoding por CPU, aplica overlays)
  - OFF → `streaming.service` (vcodec copy, sin overlays, menor CPU)
- Botones **Iniciar** y **Detener**.

El estado se actualiza automáticamente vía Server-Sent Events (`/api/events`).

---

## Vista previa local (antes de salir en vivo)

Tarjeta "Vista previa", debajo de la tarjeta de stream. Reutiliza la cámara,
el audio y los overlays ya configurados en el acordeón, pero **nunca**
transmite a la plataforma real — el backend anula `RTMP_URL` /
`RTMP_URL_SECONDARY` / `STREAM_KEY` para el proceso de preview
(`systemd/preview.service`), sin importar lo que haya guardado en el
paso "Destino".

Transportes disponibles:

- **RTMP (mediamtx)** — publica a `rtmp://localhost:1935/<nombre>`.
  Requiere mediamtx instalado y corriendo en la Pi
  (`scripts/mediamtx-install.sh`, `make start-preview` no lo instala).
  Cualquier equipo de la LAN puede verlo a la vez con
  `vlc rtmp://<ip-pi>:1935/<nombre>`.
- **TCP (MPEG-TS)** — la Pi escucha en el puerto indicado; el cliente
  conecta con `vlc tcp://<ip-pi>:<puerto>` después de iniciar.
- **UDP (MPEG-TS)** — la Pi empuja al "IP del cliente" indicado; ese
  cliente debe tener VLC abierto en `vlc udp://@:<puerto>` antes de iniciar.

Botón "Iniciar preview" guarda la configuración de transporte
(`PUT /api/preview/config`) y arranca el servicio
(`POST /api/stream/preview/start`) en un solo paso. Como `preview` comparte
cámara con `streaming`/`streaming-overlay`, iniciar uno detiene
automáticamente los otros (mismo mecanismo que ya evita que dos pipelines
de ffmpeg compitan por la cámara).

---

## Actualizar usuarios o rotar contraseñas

```bash
SOPS_AGE_KEY_FILE=/etc/raspi-streaming/age/key.txt scripts/manage-users.sh list
make add-user WEBAPI_USER=admin WEBAPI_ROLE=operator   # sobreescribe si ya existe
SOPS_AGE_KEY_FILE=/etc/raspi-streaming/age/key.txt scripts/manage-users.sh remove invitado
```

Tras modificar usuarios, copiar el `secrets.enc.yaml` actualizado al directorio
de instalación y reiniciar:

```bash
make restart-web-api
```

---

## Variables de `/etc/streaming.env`

Este archivo es compartido entre los servicios systemd y la web API.
Se reescribe completamente en cada `PUT /api/config`.

| Variable | Descripción |
|---|---|
| `RTMP_URL` | URL RTMP completa incluyendo stream key (primary) |
| `STREAM_PLATFORM` | `youtube` / `facebook` / `custom` / `dual` |
| `STREAM_KEY` | Stream key de la plataforma principal |
| `STREAM_DUAL` | `true` para activar dual stream |
| `STREAM_KEY_META` | Stream key de Facebook (solo en modo dual) |
| `RTMP_URL_SECONDARY` | URL RTMP de Facebook compuesta (solo en modo dual) |
| `STREAM_WIDTH` / `STREAM_HEIGHT` | Resolución de video en píxeles |
| `STREAM_FPS` | Fotogramas por segundo |
| `STREAM_BITRATE` | Bitrate de video en bps |
| `STREAM_PRESET` | Preset libx264 (`ultrafast`…`fast`) |
| `VIDEO_DEVICE` | Dispositivo de video (`/dev/videoN` o vacío para auto) |
| `AUDIO_DEVICE` | Dispositivo ALSA (`plughw:N,M` o vacío para auto) |
| `AUDIO_CHANNELS` | `1` mono / `2` stereo |
| `AUDIO_RATE` | Sample rate en Hz (`44100` / `48000`) |
| `STREAM_NO_AUDIO` | `true` para silencio AAC (requerido por YouTube sin micrófono) |
| `STREAM_AUDIO_BOOST` | `true` aplica `aresample=async=1,volume=2.0` al audio |
| `OVERLAY_TEXT` | Texto libre en esquina |
| `OVERLAY_TEXT_POS` | `tl` / `tr` / `bl` / `br` / `center` |
| `OVERLAY_TIMESTAMP` | `true` para timestamp en tiempo real |
| `OVERLAY_LOGO_FILE` | Ruta absoluta al PNG del logo |
| `OVERLAY_LOGO_POS` | `tl` / `tr` / `bl` / `br` |
| `OVERLAY_LOGO_PAD` | Margen del logo en píxeles |
| `OVERLAY_LOGO_W` | Ancho del logo en px (0 = tamaño original) |
| `OVERLAY_BANNER` | Texto del banner (barra negra + texto centrado) |
| `OVERLAY_BANNER_POS` | `footer` (inferior) / `header` (superior) |

---

## Variables de `/etc/preview.env`

Solo el destino del preview — cámara/audio/overlays se leen de
`/etc/streaming.env` (compartido). Se reescribe completamente en cada
`PUT /api/preview/config`.

| Variable | Descripción |
|---|---|
| `PREVIEW_TRANSPORT` | `rtmp` / `tcp` / `udp` |
| `PREVIEW_PORT` | puerto para `rtmp` (mediamtx, default 1935), `tcp` o `udp` |
| `PREVIEW_CLIENT_IP` | IP destino, requerido solo para `udp` |
| `PREVIEW_RTMP_NAME` | path del stream en mediamtx, solo para `rtmp` (default `preview`) |

---

## Variables de `/etc/web-api.env`

| Variable | Descripción |
|---|---|
| `SECRET_KEY` | firma las cookies de sesión Flask; no debe filtrarse |
| `PORT` | puerto HTTPS (default 8443) |
| `TLS_CERT` / `TLS_KEY` | certificado autofirmado generado en la instalación |
| `SECRETS_PATH` | ruta al `secrets.enc.yaml` instalado |
| `STREAMING_ENV_PATH` | ruta a `/etc/streaming.env` |
| `PREVIEW_ENV_PATH` | ruta a `/etc/preview.env` |
| `LOGO_UPLOAD_DIR` | directorio para logos subidos (default `/var/lib/raspi-streaming/assets/logos`) |
| `SOPS_AGE_KEY_FILE` | ruta a la age key privada |

---

## Limitaciones conocidas

- El API controla `streaming`, `streaming-overlay` y `preview`; no expone
  `mediamtx` ni `motion-trigger` (el preview vía RTMP requiere que
  `mediamtx` ya esté corriendo aparte).
- No hay endpoint de recarga en caliente de usuarios: tras `manage-users.sh`,
  hacer `systemctl restart web-api`.
- El certificado es autofirmado: cada cliente nuevo debe aceptar el aviso
  una vez. Para evitarlo, reemplazar por un certificado real (p.ej. Let's
  Encrypt vía DNS challenge) y apuntar `TLS_CERT`/`TLS_KEY` a esos archivos.
- El modo dual stream requiere suficiente ancho de banda de subida para
  dos streams simultáneos; en conexiones lentas puede causar drops.
