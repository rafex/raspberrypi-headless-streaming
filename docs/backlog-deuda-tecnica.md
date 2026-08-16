# Backlog de deuda técnica

Generado a partir del análisis general del proyecto (2026-08-16). Cada ítem incluye contexto y una propuesta de acción, sin prioridad implícita en el orden.

## 1. Sin CI/lint que verifique el bit `+x` en `scripts/*.sh`

**Problema:** no existe ningún chequeo automático que garantice que los scripts de `scripts/` mantengan permisos de ejecución. Esto ya causó una regresión real en el commit `e038101`, donde `ensure-gpu-encoder.sh` perdió el bit `+x`.

**Propuesta:** agregar un step de CI (o un pre-commit hook) que corra algo como `find scripts -name '*.sh' ! -perm -u+x -print -exec false {} +` y falle el build si encuentra scripts sin permiso de ejecución.

## 2. `AUTO_STREAM_DELAY_SECONDS=600` hardcodeado en múltiples lugares

**Problema:** el valor del delay de arranque está duplicado en `.env.example`, el default del script orquestador y la documentación. Ya se desincronizó dos veces (120→420→600).

**Propuesta:** centralizar el valor en una única fuente de verdad (por ejemplo, que el script lea únicamente de `boot-flow.env` sin default hardcodeado, o generar la documentación a partir del `.env.example`) para evitar que vuelvan a divergir.

## 3. `backend/api/.venv/` y `.opencode/node_modules/` posiblemente versionados

**Problema:** estos directorios parecen estar trackeados en git sin exclusión vía `.gitignore`, infringiendo miles de archivos vendored al repo.

**Propuesta:** confirmar con `git ls-files` si están efectivamente versionados: de ser así, agregarlos a `.gitignore` y removerlos del árbol (`git rm -r --cached`).

## 4. Duplicación entre `backend/` (FastAPI) y `server/webapi/`

**Problema:** coexisten dos implementaciones de API web — `backend/api/src/streaming_api/` (FastAPI, con mTLS y Helm chart) y `server/webapi/` (más antigua, estilo Flask) — sin que quede claro cuál es la vigente.

**Propuesta:** definir con el mantenedor cuál de las dos es la actual/soportada y deprecar o eliminar la otra para evitar mantenimiento duplicado y confusión.

## 5. Fallbacks silenciosos por diseño (`|| true`, `exit 0` siempre)

**Problema:** varias capas del pipeline (detección de hardware, `ensure-gpu-encoder.sh`, etc.) tragan errores intencionalmente para que el streaming nunca se bloquee. Es una decisión razonable para resiliencia, pero fue justamente lo que ocultó en su momento el bug del GPU encoder no detectado tras reboot (solo visible en logs de journal).

**Propuesta:** sin cambiar el comportamiento de resiliencia, agregar señales explícitas y visibles de estos fallbacks (ej. un log destacado o una métrica/health-check expuesta en el `health-reporter.service`) para que un fallback a CPU encoding u otro modo degradado sea detectable sin tener que revisar journal manualmente.
