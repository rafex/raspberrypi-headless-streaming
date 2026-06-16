# Web API: control de la transmisión desde el celular

API REST + frontend ligero, servidos por el mismo proceso (gunicorn + Flask)
sobre HTTPS con certificado autofirmado, que permite encender/apagar la
transmisión y revisar su estado sin entrar por SSH. Corre en la Pi 3B (el
nodo de streaming), junto a los servicios `streaming` / `streaming-overlay`
que ya gestiona [`scripts/control.sh`](../scripts/control.sh).

---

## Componentes

| Pieza | Rol |
|---|---|
| `server/webapi/app.py` | API REST + sirve el frontend estático |
| `server/webapi/secrets_store.py` | descifra usuarios con `sops`+`age` en memoria |
| `server/webapi/auth.py` | login por sesión (cookie), CSRF, roles |
| `server/webapi/stream_control.py` | `systemctl start/stop/status` de los dos servicios |
| `server/webapi/config_store.py` | lee/escribe `/etc/streaming.env` |
| `server/webapi/static/` | frontend (HTML/CSS/JS vanilla, sin build) |
| `scripts/manage-users.sh` | alta/baja/listado de usuarios cifrados |
| `scripts/web-api-install.sh` | instala venv (con `uv`), TLS, sudoers, systemd unit |

### Roles

- **viewer**: ve el estado de los servicios y la configuración (con el
  destino RTMP enmascarado).
- **operator**: además puede iniciar/detener la transmisión y editar la
  configuración (incluye el destino RTMP completo).

### Seguridad

- Las contraseñas se guardan hasheadas (PBKDF2-SHA256) dentro de un YAML
  cifrado con `sops`+`age` — nunca en texto plano, ni en el repo ni en disco.
- La age key privada solo vive en la Pi (`/etc/raspi-streaming/age/key.txt`,
  permisos 600), nunca se versiona.
- El servicio corre como un usuario de sistema sin privilegios (`webapi`),
  con permiso `sudo` acotado únicamente a `systemctl start|stop` de
  `streaming.service` y `streaming-overlay.service`.
- HTTPS con certificado autofirmado: el navegador del celular mostrará un
  aviso de seguridad la primera vez, hay que aceptarlo explícitamente.

---

## Instalación paso a paso

Todo el flujo de instalación corre con `make`, en este orden (o de una sola
vez con `make setup`):

### 1. Instalar dependencias

```bash
make deps-web-api
```

Corre `sudo scripts/install-deps.sh --web-api`, que instala `age`, `sops`,
`uv`, `openssl` y `python3-yaml`. `uv` se instala como `root` (el script
corre con `sudo`), quedando en `/usr/local/bin/uv`, visible también para
`web-api-install.sh` más adelante. `sops` no siempre está empaquetado en
Debian según la versión — si avisa que no pudo instalarlo por `apt`,
instalarlo manualmente desde
[https://github.com/getsops/sops/releases](https://github.com/getsops/sops/releases).

(`sudo scripts/install-deps.sh --full` si además querés todo lo demás:
cámaras, servidor IA, etc.)

### 2. Generar la age key y configurar `.sops.yaml`

```bash
make age-key
```

Corre `scripts/web-api-setup-age.sh`, que genera (si no existe)
`/etc/raspi-streaming/age/key.txt` y reemplaza automáticamente el
placeholder de `.sops.yaml` con la public key generada — no hace falta
editar nada a mano.

### 3. Crear el primer usuario

```bash
make add-user WEBAPI_USER=admin WEBAPI_ROLE=operator
```

Pide la contraseña por terminal (oculta) y crea
`server/webapi/secrets.enc.yaml` cifrado. Repetir con otro usuario/rol para
agregar más cuentas, por ejemplo un `viewer` que solo puede ver el estado:

```bash
make add-user WEBAPI_USER=invitado WEBAPI_ROLE=viewer
```

Para administrar usuarios directamente (listar, quitar), usar
`scripts/manage-users.sh` (`add <usuario> <viewer|operator>`,
`remove <usuario>`, `list`), con `SOPS_AGE_KEY_FILE=/etc/raspi-streaming/age/key.txt`.

### 4. Instalar y habilitar en boot

```bash
make web-api
```

Corre `scripts/web-api-install.sh` (que verifica `sops`/`age`/`uv`, crea el
usuario de sistema `webapi`, el venv en `/opt/web-api/venv` (con `uv`), el
certificado TLS autofirmado, `/etc/web-api.env` con un `SECRET_KEY`
aleatorio y el sudoers acotado) y luego `systemctl enable --now
web-api.service`, para que el servicio quede arrancando solo en cada boot
de la Pi.

Equivale a correr por separado:

```bash
make install-web-api   # sudo scripts/web-api-install.sh
make enable-web-api    # sudo systemctl enable --now web-api.service
```

Otros atajos: `make status-web-api`, `make logs-web-api`,
`make restart-web-api`, `make stop-web-api`, `make disable-web-api`
(`make help` lista todos).

### 6. Acceder desde el celular

```
https://<ip-de-la-pi>:8443
```

El navegador mostrará un aviso de certificado no confiable (es autofirmado):
aceptar y continuar. Iniciar sesión con el usuario creado en el paso 3.

---

## Actualizar usuarios o rotar contraseñas

```bash
SOPS_AGE_KEY_FILE=/etc/raspi-streaming/age/key.txt scripts/manage-users.sh list
make add-user WEBAPI_USER=admin WEBAPI_ROLE=operator   # sobreescribe si ya existe
SOPS_AGE_KEY_FILE=/etc/raspi-streaming/age/key.txt scripts/manage-users.sh remove invitado
```

Después de modificar usuarios, copiar el `secrets.enc.yaml` actualizado a
`/opt/web-api/webapi/secrets.enc.yaml` (o volver a correr
`web-api-install.sh`) y reiniciar el servicio:

```bash
make restart-web-api
```

---

## Variables de `/etc/web-api.env`

| Variable | Descripción |
|---|---|
| `SECRET_KEY` | firma las cookies de sesión Flask; no debe filtrarse |
| `PORT` | puerto HTTPS (default 8443) |
| `TLS_CERT` / `TLS_KEY` | certificado autofirmado generado en la instalación |
| `SECRETS_PATH` | ruta al `secrets.enc.yaml` instalado |
| `STREAMING_ENV_PATH` | ruta a `/etc/streaming.env` (compartido con los servicios de streaming) |
| `SOPS_AGE_KEY_FILE` | ruta a la age key privada usada para descifrar `SECRETS_PATH` |

---

## Limitaciones conocidas

- El API solo controla `streaming` y `streaming-overlay`; no expone
  `mediamtx` ni `motion-trigger`.
- No hay endpoint de recarga en caliente de usuarios: tras `manage-users.sh`,
  hay que `systemctl restart web-api`.
- El certificado es autofirmado: cada cliente nuevo debe aceptar el aviso
  una vez. Si se prefiere evitar ese aviso, se puede reemplazar por un
  certificado real (Let's Encrypt vía DNS challenge, por ejemplo) apuntando
  `TLS_CERT`/`TLS_KEY` a esos archivos.
