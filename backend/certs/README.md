# Certificados

Esta carpeta guarda ejemplos y destinos locales para certificados. No subir
claves reales.

- `backend/certs/backend/`: CA/secret usado por el backend/Ingress para validar mTLS.
- `backend/certs/frontend/`: certificado cliente para la Raspi u otros clientes autorizados.

Generar certificados de desarrollo:

```bash
backend/helpers/generate-dev-certs.sh
```

Instalar el certificado cliente en la Raspi:

```bash
backend/helpers/install-raspi-client-certs.sh root@192.168.3.169
```

Crear secrets en Kubernetes:

```bash
backend/helpers/create-k8s-secrets.sh mvps
```
