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

Generar solo un token bearer:

```bash
make backend-token
make backend-admin-token
```

Generar CA mTLS y certificado cliente:

```bash
make backend-certs BACKEND_DEVICE_ID=raspi3b
```

Flujo recomendado para inicializar todo el material local:

```bash
make backend-secrets BACKEND_DEVICE_ID=raspi3b
```

Ese comando crea:

```text
backend/certs/backend/ca.crt
backend/certs/backend/ca.key
backend/certs/frontend/raspi3b.crt
backend/certs/frontend/raspi3b.key
backend/helpers/raspi-backend.env.local
```

Tambien imprime una sola vez los valores para reemplazar los GitHub Secrets:

```text
STREAMING_API_RASPI_TOKEN
STREAMING_API_ADMIN_TOKEN
STREAMING_API_CLIENT_CA_CRT_B64
```

Luego instala el certificado cliente en la Raspi:

```bash
make backend-install-raspi-certs RASPI_SSH=root@192.168.3.169 BACKEND_DEVICE_ID=raspi3b
```

Crear el secret de CA cliente en k3s:

```bash
backend/helpers/create-k8s-secrets.sh streaming-rafex-io
```

## GitHub Actions

El workflow `.github/workflows/streaming-api.yml` construye la imagen en GHCR,
configura `kubectl` con `KUBE_CONFIG_DATA` y despliega con Helm.

Secrets requeridos:

```text
KUBE_CONFIG_DATA
STREAMING_API_RASPI_TOKEN
STREAMING_API_ADMIN_TOKEN
STREAMING_API_CLIENT_CA_CRT_B64
```

`KUBE_CONFIG_DATA` es el kubeconfig del cluster codificado en base64.

La publicacion a GHCR usa `GITHUB_TOKEN`, el token automatico de GitHub
Actions, por lo que no requiere un secret extra para paquetes.

`STREAMING_API_CLIENT_CA_CRT_B64` se genera con:

```bash
base64 -i backend/certs/backend/ca.crt
```

Los GitHub Secrets ya pueden existir con valores dummy; reemplazalos desde la
UI de GitHub o con `gh secret set <NOMBRE>`. `raspi-backend.env.local` esta
ignorado por git.
