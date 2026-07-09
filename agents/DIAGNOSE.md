# Diagnóstico del Proyecto

_Fecha: 2026-07-08 | Repositorio: raspberrypi-headless-streaming_

---

## 1. Exploración

### Estructura general
Proyecto organizado por responsabilidad, sin código fuente compilado:

- `scripts/` — scripts Bash principales (`stream.sh`, `stream-overlay.sh`, `record.sh`)
- `assets/` — imágenes para overlays (`logo.png`, `frame.png`)
- `systemd/` — unidad de servicio (`streaming.service`) para ejecución automática
- `docs/` — guías (`setup.md`, `architecture.md`)
- `spec-native/` — contexto SpecNative (PRODUCT, ARCHITECTURE, STACK, etc.)
- `.specnative/` — infraestructura del framework SpecNative
- Raíz — `README.md`, `AGENTS.md`, `TODO.md`, `package.json`, `package-lock.json`

### Lenguajes y tecnologías
Bash, Python, JavaScript, Markdown. Herramientas de dominio: `libcamera-vid` (captura HW), `ffmpeg` (procesado y streaming), RTMP (YouTube/Facebook), `systemd` (automatización).

### Sistema de build / dependencias
`npm` con `package.json` + `package-lock.json`. Dependencia declarada: `eslint`. El npm script `test` es un placeholder (`exit 1`). Sin Docker ni CI/CD.

### Puntos de entrada
- `scripts/stream.sh` — captura + streaming RTMP
- `scripts/stream-overlay.sh` — captura + overlays + streaming
- `scripts/record.sh` — grabación local
- `systemd/streaming.service` — arranque automático como servicio

### Módulos y componentes clave
- **Camera Capture** — `libcamera-vid` produce H264 a stdout
- **Video Processing & Streaming** — `ffmpeg` empaqueta y envía a RTMP
- **Overlay System** — filtros `ffmpeg` con `assets/logo.png` y `frame.png`
- **Automation** — `systemd` orquesta el pipeline `captura → encoder → ffmpeg → RTMP`

### Archivos de configuración relevantes
`.gitignore`, `systemd/streaming.service`, `docs/setup.md`, `docs/architecture.md`, `AGENTS.md`, `TODO.md`, `package.json`, y el contexto extenso en `spec-native/` y `.specnative/`. No hay Dockerfile ni pipelines de CI/CD.

### Estado del repositorio
Rama `main`, sin remote branches. Último commit `6c45b1e` — "docs: add AGENTS.md and refine project structure" (2024-06-07, Rafal Kwasny). Sin archivos untracked ni modificados.

---

## 2. Revisión de calidad

### Problemas estructurales o de diseño
- **[Alto]** Ausencia total de tests en los scripts críticos (`stream.sh`, `stream-overlay.sh`, `record.sh`); el npm script `test` es un placeholder.
- **[Medio]** `systemd/streaming.service` contiene placeholders (`__STREAM_USER__`, `__REPO_DIR__`) sin documentación de reemplazo.

### Deuda técnica identificada
- **[Medio]** `stream-overlay.sh` incluye lógica `filter_complex` compleja sin comentarios explicativos.
- **[Bajo]** Variables como `AUDIO_BOOST` podrían reutilizarse entre scripts para consistencia.
- **[Bajo]** La unidad systemd no define límites de memoria (`MemoryMax`), riesgo de OOM en Raspberry Pi.

### Prácticas del lenguaje no seguidas
- **Bash:** ✅ shebang correcto, `set -euo pipefail`, validación de parámetros con regex, funciones para mensajes de error, `command -v` para verificar dependencias. ❌ Falta manejo de errores en pipes complejos (`libcamera-vid | ffmpeg`), donde un fallo en cualquier extremo del pipe puede pasar desapercibido.

### Riesgos de seguridad
- ✅ No hay secretos hardcodeados; `RTMP_URL` y `STREAM_KEY` se manejan vía variables de entorno.
- ❌ `.gitignore` no ignora archivos `.env`, lo que podría llevar a versionar credenciales por accidente.

### Cobertura de tests y documentación
- **[Alto]** No existen tests para validación de parámetros, manejo de errores (cámara no conectada) ni validación de URLs RTMP.
- **[Medio]** Conviene verificar que `docs/setup.md` y `docs/architecture.md` cubran hardware, dependencias y flujos de ejecución.

_Nota: el informe de auditoría afirmó erróneamente que `package.json` estaba ausente; la exploración confirmó que existe junto con `package-lock.json`. Esa afirmación fue descartada._

---

## 3. Síntesis ejecutiva

### Resumen del proyecto
Sistema headless para Raspberry Pi que captura video desde una cámara, aplica overlays opcionales (logo, marco, texto) y transmite en vivo vía RTMP a plataformas como YouTube o Facebook, operando únicamente desde CLI sin entorno gráfico ni OBS. Se organiza en `scripts/` (Bash), `assets/`, `systemd/`, `docs/` y contexto SpecNative. Tecnologías: Bash, `libcamera-vid`, `ffmpeg`, RTMP, `systemd` y npm (con `eslint`).

### Estado de salud
**🟡 Amarillo** — El proyecto funciona, está bien documentado y sigue buenas prácticas de Bash, pero la ausencia de pruebas automatizadas y la falta de configuraciones de resiliencia en systemd representan riesgos operacionales antes de considerarlo estable.

### Top 3 fortalezas
1. Arquitectura clara y minimalista — solo CLI, sin dependencias pesadas ni Docker, ideal para Pi con recursos limitados.
2. Buenas prácticas de Bash — shebang, `set -euo pipefail`, verificación de dependencias con `command -v`, validación de parámetros con regex.
3. Seguridad básica correcta — sin secretos hardcodeados; credenciales RTMP vía variables de entorno.

### Top 3 riesgos o deudas
1. Falta de pruebas automatizadas — scripts críticos sin tests; errores de parámetros o fallos de cámara pueden pasar desapercibidos en producción.
2. Service file incompleto — `streaming.service` con placeholders sin documentar y sin límites de recursos (`MemoryMax`), riesgo de OOM o ejecución bajo usuario incorrecto.
3. Gestión de errores en pipelines — sin manejo de fallos en `libcamera-vid | ffmpeg`, lo que dificulta la recuperación automática.

### Próximos pasos recomendados
1. Implementar pruebas Bash (p. ej. Bats) para validar parámetros, manejo de errores y comportamiento con cámara ausente o URL RTMP inválida — **impacto alto**.
2. Completar y robustecer `streaming.service` — reemplazar placeholders con variables configurables, añadir `MemoryMax`, `Restart=on-failure` y documentar los campos — **impacto medio**.
3. Mejorar manejo de errores en pipelines usando `${PIPESTATUS[@]}` y logs claros; añadir `.env` a `.gitignore` y definir scripts npm de lint (`eslint`) con miras a un CI ligero (GitHub Actions) — **impacto medio**.

---

## 4. Archivos relevantes

| Archivo | Tipo | Relevancia |
|---------|------|------------|
| `scripts/stream.sh` | entry | Pipeline principal captura → streaming RTMP; núcleo del sistema |
| `scripts/stream-overlay.sh` | entry | Streaming con overlays; contiene `filter_complex` complejo sin comentarios |
| `scripts/record.sh` | entry | Grabación local del stream |
| `systemd/streaming.service` | config | Automatización; placeholders sin documentar y sin límites de recursos |
| `package.json` | config | Gestión npm y `eslint`; script `test` es placeholder |
| `.gitignore` | config | No ignora `.env`; riesgo de versionar credenciales |
| `assets/logo.png` | module | Recurso de overlay usado por `stream-overlay.sh` |
| `assets/frame.png` | module | Recurso de overlay (marco) |
| `docs/setup.md` | config | Guía de instalación; verificar cobertura |
| `docs/architecture.md` | config | Documentación de arquitectura del pipeline |
