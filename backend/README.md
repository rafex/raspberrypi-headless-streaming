# Streaming API backend

Backend publico para recibir salud de la Raspi y publicar configuracion/comandos
deseados para que la Raspi los consuma por polling seguro.

Dominio objetivo:

```text
https://streaming.rafex.io
```

## Autenticacion

La API exige dos capas:

- Token bearer: `API_TOKEN_RASPI` para la Raspi y `API_TOKEN_ADMIN` para clientes admin.
- mTLS: el Ingress debe validar el certificado cliente y reenviar headers al backend.

Headers esperados por defecto:

```text
X-SSL-Client-Verify: SUCCESS
X-SSL-Client-Subject: ...
X-SSL-Client-CN: ...
```

En desarrollo se puede iniciar con `REQUIRE_MTLS=false`.

## Endpoints

```text
GET  /healthz
POST /v1/raspi/{device_id}/health
GET  /v1/raspi/{device_id}/desired-state
POST /v1/raspi/{device_id}/ack
PUT  /v1/raspi/{device_id}/desired-state   # admin
GET  /v1/raspi/{device_id}/state           # admin
GET  /v1/raspi                             # admin
```

La Raspi consume `desired-state` con `scripts/backend-control-agent.py`; ese
agente aplica cambios en `/etc/streaming.env` y ejecuta solo comandos acotados.

Ejemplo para mover configuracion deseada:

```bash
curl -X PUT https://streaming.rafex.io/v1/raspi/raspi3b/desired-state \
  -H "Authorization: Bearer ${API_TOKEN_ADMIN}" \
  -H "Content-Type: application/json" \
  --cert backend/certs/frontend/raspi-client.crt \
  --key backend/certs/frontend/raspi-client.key \
  -d '{
    "config": {
      "OVERLAY_TEXT": "https://theworldofrafex.blog",
      "OVERLAY_TIMESTAMP": "true"
    },
    "command": {
      "action": "apply_config",
      "reason": "actualizar overlay"
    }
  }'
```

## Local

```bash
cd backend/api
uv sync
API_TOKEN_RASPI=dev-raspi \
API_TOKEN_ADMIN=dev-admin \
REQUIRE_MTLS=false \
DATABASE_PATH=/tmp/streaming-api.db \
uv run uvicorn streaming_api.app:app --reload --host 0.0.0.0 --port 8080
```

## Certificados

Generar CA y certificado cliente de desarrollo:

```bash
backend/helpers/generate-dev-certs.sh
```

Instalar certificado cliente en la Raspi:

```bash
backend/helpers/install-raspi-client-certs.sh root@192.168.3.169
```

Crear el secret de CA cliente en k3s:

```bash
backend/helpers/create-k8s-secrets.sh mvps
```

## GitHub Actions

El workflow `.github/workflows/streaming-api.yml` construye la imagen en GHCR y
despliega por SSH en `my-k3s-2` con Helm.

Secrets requeridos:

```text
GH_TOKEN_PACKAGES
K3S_SSH_USER
K3S_SSH_PRIVATE_KEY
STREAMING_API_RASPI_TOKEN
STREAMING_API_ADMIN_TOKEN
STREAMING_API_CLIENT_CA_CRT_B64
```

`STREAMING_API_CLIENT_CA_CRT_B64` se genera con:

```bash
base64 -i backend/certs/backend/ca.crt
```
