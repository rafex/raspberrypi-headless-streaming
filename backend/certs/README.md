# Certificados

Esta carpeta guarda ejemplos y destinos locales para certificados. No subir
claves reales.

- `backend/certs/backend/`: CA/secret usado por el backend/Ingress para validar mTLS.
- `backend/certs/frontend/`: certificado cliente para la Raspi u otros clientes autorizados.

Generar CA y certificado cliente:

```bash
backend/helpers/streaming-api-secrets.py certs --device-id raspi3b
```

Generar tokens, certificados y archivos `.env.local` de operación:

```bash
backend/helpers/streaming-api-secrets.py init --device-id raspi3b
```

Instalar el certificado cliente en la Raspi:

```bash
backend/helpers/install-raspi-client-certs.sh root@192.168.3.169
```

Crear secrets en Kubernetes:

```bash
backend/helpers/create-k8s-secrets.sh streaming-rafex-io
```
