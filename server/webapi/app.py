"""
API REST + frontend estático para controlar la transmisión desde el celular.

Sirve sobre HTTPS (gunicorn --certfile/--keyfile, ver systemd/web-api.service).
Los usuarios/roles vienen de un archivo cifrado con sops+age
(server/webapi/secrets_store.py); la sesión es una cookie firmada con
SECRET_KEY; el control de servicios systemd vive en stream_control.py;
la configuración de /etc/streaming.env vive en config_store.py.

Variables de entorno relevantes (ver systemd/web-api.service / /etc/web-api.env):
    SECRET_KEY            clave de firma de sesión Flask (obligatoria)
    SECRETS_PATH          ruta a secrets.enc.yaml (default: junto a este archivo)
    STREAMING_ENV_PATH    ruta a streaming.env (default: /etc/streaming.env)
    PORT                  puerto HTTP interno (gunicorn lo bindea, no Flask)
"""

import json
import logging
import os
import threading
import time
from datetime import timedelta

from flask import Flask, Response, jsonify, request, send_from_directory, session, stream_with_context
from flask_limiter import Limiter
from flask_limiter.util import get_remote_address
from werkzeug.utils import secure_filename

from . import auth, config_store, device_detect, mic_control, preview_store, secrets_store, stream_control

# Límite de conexiones SSE simultáneas — cada una ocupa un worker de gunicorn.
_SSE_MAX = 5
_sse_sem = threading.Semaphore(_SSE_MAX)

# Límite aparte para el stream SSE del nivel de micrófono: solo se abre mientras
# el acordeón de Audio está desplegado, y cada conexión puede disparar captura
# del device, así que lo acotamos más agresivamente.
_MIC_SSE_MAX = 3
_mic_sse_sem = threading.Semaphore(_MIC_SSE_MAX)

# Rate limiter compartido entre todas las instancias de app (factory pattern).
_limiter = Limiter(key_func=get_remote_address, storage_uri="memory://")

# Audit log — va a stdout, gunicorn lo redirige al journal de systemd.
_audit = logging.getLogger("web-api.audit")

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
LOGO_ALLOWED_EXT = {".png", ".jpg", ".jpeg"}
LOGO_MAX_BYTES = 5 * 1024 * 1024  # 5 MB

# Firmas magic bytes para validar imágenes subidas.
_MAGIC_PNG  = b"\x89PNG"
_MAGIC_JPEG = b"\xff\xd8\xff"


def _is_valid_image(data: bytes) -> bool:
    return data[:4] == _MAGIC_PNG or data[:3] == _MAGIC_JPEG


def create_app(test_config: dict | None = None) -> Flask:
    app = Flask(__name__, static_folder=STATIC_DIR, static_url_path="")

    secret_key = (test_config or {}).get("SECRET_KEY", os.environ.get("SECRET_KEY"))
    if not secret_key:
        raise RuntimeError("SECRET_KEY no definido (ver /etc/web-api.env)")

    secrets_path = (test_config or {}).get(
        "SECRETS_PATH", os.environ.get("SECRETS_PATH", os.path.join(os.path.dirname(__file__), "secrets.enc.yaml"))
    )
    streaming_env_path = (test_config or {}).get(
        "STREAMING_ENV_PATH", os.environ.get("STREAMING_ENV_PATH", "/etc/streaming.env")
    )
    preview_env_path = (test_config or {}).get(
        "PREVIEW_ENV_PATH", os.environ.get("PREVIEW_ENV_PATH", "/etc/preview.env")
    )
    logo_upload_dir = (test_config or {}).get(
        "LOGO_UPLOAD_DIR", os.environ.get("LOGO_UPLOAD_DIR", "/var/lib/raspi-streaming/assets/logos")
    )
    headless_api_token = (test_config or {}).get(
        "HEADLESS_API_TOKEN", os.environ.get("HEADLESS_API_TOKEN", "")
    )

    app.config.update(
        SECRET_KEY=secret_key,
        SESSION_COOKIE_SECURE=True,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Strict",
        PERMANENT_SESSION_LIFETIME=timedelta(hours=12),
        STREAMING_ENV_PATH=streaming_env_path,
        PREVIEW_ENV_PATH=preview_env_path,
        LOGO_UPLOAD_DIR=logo_upload_dir,
        HEADLESS_API_TOKEN=headless_api_token,
        RATELIMIT_ENABLED=True,
    )

    _limiter.init_app(app)

    @app.errorhandler(429)
    def ratelimit_handler(e):
        return jsonify({"error": "Demasiados intentos. Espera antes de reintentar."}), 429

    @app.after_request
    def security_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"
        response.headers["Content-Security-Policy"] = (
            "default-src 'self'; "
            "script-src 'self'; "
            "style-src 'self' 'unsafe-inline'; "
            "img-src 'self' data:; "
            "connect-src 'self'; "
            "frame-ancestors 'none'"
        )
        return response

    @app.before_request
    def headless_auth_context():
        request.environ["HEADLESS_API_TOKEN"] = app.config.get("HEADLESS_API_TOKEN", "")

    if (test_config or {}).get("USERS") is not None:
        users = test_config["USERS"]
    else:
        users = secrets_store.load_users(secrets_path)
    app.config["USERS"] = users

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    def _client_ip() -> str:
        return request.remote_addr or "?"

    def _user() -> str:
        return session.get("user", "?")

    # ------------------------------------------------------------------
    # Endpoints
    # ------------------------------------------------------------------

    @app.get("/api/health")
    def health():
        return jsonify({"status": "ok"})

    @app.post("/api/login")
    @_limiter.limit("5 per minute")
    def login():
        data = request.get_json(silent=True) or {}
        username = str(data.get("username", ""))
        password = str(data.get("password", ""))

        result = auth.login(app.config["USERS"], username, password)
        if result is None:
            _audit.warning("login_failed user=%s ip=%s", username, _client_ip())
            return jsonify({"error": "Usuario o contraseña inválidos"}), 401

        _audit.info("login_ok user=%s role=%s ip=%s", username, result["role"], _client_ip())
        return jsonify(result)

    @app.post("/api/logout")
    @auth.require_role("viewer")
    def logout():
        _audit.info("logout user=%s ip=%s", _user(), _client_ip())
        auth.logout()
        return jsonify({"status": "ok"})

    @app.get("/api/status")
    @auth.require_role("viewer")
    def status():
        return jsonify({svc: stream_control.status(svc) for svc in stream_control.SERVICES})

    @app.get("/api/events")
    @auth.require_role("viewer")
    def events():
        if not _sse_sem.acquire(blocking=False):
            return jsonify({"error": "Demasiadas conexiones de eventos activas"}), 429

        def generate():
            try:
                while True:
                    services = {svc: stream_control.status(svc) for svc in stream_control.SERVICES}
                    yield f"data: {json.dumps({'services': services})}\n\n"
                    time.sleep(5)
            finally:
                _sse_sem.release()

        return Response(
            stream_with_context(generate()),
            mimetype="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    @app.get("/api/devices")
    @auth.require_role("operator")
    def get_devices():
        return jsonify({
            "cameras": device_detect.list_cameras(),
            "mics":    device_detect.list_mics(),
        })

    def _resolve_audio_device() -> str:
        cfg = config_store.read_config(app.config["STREAMING_ENV_PATH"])
        if cfg.get("STREAM_NO_AUDIO") == "true":
            return ""
        dev = (cfg.get("AUDIO_DEVICE") or "").strip()
        if dev:
            return dev
        mics = device_detect.list_mics()
        return mics[0]["dev"] if mics else ""

    def _mic_snapshot(services: dict | None = None, measure: bool = True) -> dict:
        """Estado del micrófono: ganancia (siempre) y nivel (si no está ocupado).

        `services` permite reusar el status ya calculado (SSE) y evitar más
        llamadas a systemctl. En el SSE `measure=True` usa caché con TTL para
        no abrir el device en cada worker/cliente.
        """
        device = _resolve_audio_device()
        if not device:
            return {"device": "", "available": False, "busy": False,
                    "reason": "no-audio", "gain": None, "level": None}

        if services is not None:
            busy = any(services.get(svc, {}).get("active") for svc in stream_control.SERVICES)
        else:
            busy = any(stream_control.is_active(svc) for svc in stream_control.SERVICES)

        gain = mic_control.get_gain(device)
        level = None
        if measure and not busy:
            # max_age=4s: el loop SSE gira cada 5s, así clientes concurrentes
            # comparten una sola captura por ventana.
            level = mic_control.measure_level(device, max_age=4.0)

        if busy:
            reason = "busy"
        elif level is None:
            reason = "no-signal"
        else:
            reason = "ok"

        return {
            "device": device,
            "available": not busy and level is not None,
            "busy": busy,
            "reason": reason,
            "gain": gain,
            "level": level,
        }

    @app.get("/api/mic/status")
    @auth.require_role("operator")
    def mic_status():
        return jsonify(_mic_snapshot(measure=True))

    @app.get("/api/mic/events")
    @auth.require_role("operator")
    def mic_events():
        """Stream SSE del nivel del micrófono.

        El frontend abre esta conexión SOLO mientras el acordeón de Audio está
        desplegado y la cierra al plegarlo, así no se mide el device cuando
        nadie está mirando. measure_level cachea entre workers (TTL 4s).
        """
        if not _mic_sse_sem.acquire(blocking=False):
            return jsonify({"error": "Demasiadas conexiones de micrófono activas"}), 429

        def generate():
            try:
                while True:
                    yield f"data: {json.dumps(_mic_snapshot(measure=True))}\n\n"
                    time.sleep(5)
            finally:
                _mic_sse_sem.release()

        return Response(
            stream_with_context(generate()),
            mimetype="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    @app.put("/api/mic/gain")
    @auth.require_role("operator")
    def mic_gain():
        data = request.get_json(silent=True) or {}
        raw = data.get("percent")
        try:
            percent = int(raw)
        except (TypeError, ValueError):
            return jsonify({"error": "percent debe ser un entero entre 0 y 100"}), 400
        if not (0 <= percent <= 100):
            return jsonify({"error": "percent debe estar entre 0 y 100"}), 400

        device = _resolve_audio_device()
        if not device:
            return jsonify({"error": "No hay micrófono configurado"}), 400

        try:
            gain = mic_control.set_gain(device, percent)
        except mic_control.MicControlError as exc:
            return jsonify({"error": str(exc)}), 400

        _audit.info("mic_gain_set user=%s ip=%s device=%s percent=%d", _user(), _client_ip(), device, percent)
        return jsonify({"device": device, "gain": gain})


    @app.get("/api/config")
    @auth.require_role("viewer")
    def get_config():
        cfg = config_store.read_config(app.config["STREAMING_ENV_PATH"])
        if session.get("role") != "operator":
            cfg = dict(cfg)
            cfg["RTMP_URL"] = config_store.mask_rtmp_url(cfg["RTMP_URL"])
        return jsonify(cfg)

    @app.put("/api/config")
    @auth.require_role("operator")
    def put_config():
        data = request.get_json(silent=True) or {}
        try:
            validated = config_store.validate_config(data)
        except config_store.ConfigValidationError as exc:
            return jsonify({"error": str(exc)}), 400

        config_store.write_config(app.config["STREAMING_ENV_PATH"], validated)
        _audit.info(
            "config_saved user=%s ip=%s platform=%s resolution=%sx%s",
            _user(), _client_ip(),
            validated.get("STREAM_PLATFORM", "?"),
            validated.get("STREAM_WIDTH", "?"),
            validated.get("STREAM_HEIGHT", "?"),
        )
        return jsonify(validated)

    @app.get("/api/preview/config")
    @auth.require_role("operator")
    def get_preview_config():
        return jsonify(preview_store.read_config(app.config["PREVIEW_ENV_PATH"]))

    @app.put("/api/preview/config")
    @auth.require_role("operator")
    def put_preview_config():
        data = request.get_json(silent=True) or {}
        try:
            validated = preview_store.validate_config(data)
        except preview_store.ConfigValidationError as exc:
            return jsonify({"error": str(exc)}), 400

        preview_store.write_config(app.config["PREVIEW_ENV_PATH"], validated)
        _audit.info(
            "preview_config_saved user=%s ip=%s transport=%s port=%s",
            _user(), _client_ip(),
            validated.get("PREVIEW_TRANSPORT", "?"),
            validated.get("PREVIEW_PORT", "?"),
        )
        return jsonify(validated)

    @app.post("/api/stream/<service>/start")
    @auth.require_role("operator")
    def stream_start(service):
        try:
            result = stream_control.start(service)
            _audit.info("stream_start user=%s ip=%s service=%s active=%s", _user(), _client_ip(), service, result.get("active"))
            return jsonify(result)
        except stream_control.StreamControlError as exc:
            _audit.warning("stream_start_failed user=%s ip=%s service=%s error=%s", _user(), _client_ip(), service, exc)
            return jsonify({"error": str(exc)}), 400

    @app.post("/api/stream/<service>/stop")
    @auth.require_role("operator")
    def stream_stop(service):
        try:
            result = stream_control.stop(service)
            _audit.info("stream_stop user=%s ip=%s service=%s", _user(), _client_ip(), service)
            return jsonify(result)
        except stream_control.StreamControlError as exc:
            _audit.warning("stream_stop_failed user=%s ip=%s service=%s error=%s", _user(), _client_ip(), service, exc)
            return jsonify({"error": str(exc)}), 400

    @app.post("/api/stream/stop-all")
    @auth.require_role("operator")
    def stream_stop_all():
        try:
            result = stream_control.stop_all()
            _audit.info("stream_stop_all user=%s ip=%s", _user(), _client_ip())
            return jsonify(result)
        except stream_control.StreamControlError as exc:
            _audit.warning("stream_stop_all_failed user=%s ip=%s error=%s", _user(), _client_ip(), exc)
            return jsonify({"error": str(exc)}), 400

    @app.post("/api/logo")
    @auth.require_role("operator")
    def upload_logo():
        if "file" not in request.files:
            return jsonify({"error": "Campo 'file' requerido"}), 400
        f = request.files["file"]
        if not f.filename:
            return jsonify({"error": "Nombre de archivo vacío"}), 400

        ext = os.path.splitext(f.filename)[1].lower()
        if ext not in LOGO_ALLOWED_EXT:
            return jsonify({"error": f"Formato no soportado. Usar: {', '.join(LOGO_ALLOWED_EXT)}"}), 400

        # Leer primero para validar tamaño y magic bytes sin guardar en disco.
        data = f.read(LOGO_MAX_BYTES + 1)
        if len(data) > LOGO_MAX_BYTES:
            return jsonify({"error": "Archivo demasiado grande (máx. 5 MB)"}), 400
        if not _is_valid_image(data):
            return jsonify({"error": "El archivo no es una imagen PNG o JPEG válida"}), 400

        filename = secure_filename(f.filename)
        if not filename:
            return jsonify({"error": "Nombre de archivo inválido"}), 400

        upload_dir = app.config["LOGO_UPLOAD_DIR"]
        os.makedirs(upload_dir, mode=0o755, exist_ok=True)

        dest = os.path.join(upload_dir, filename)
        with open(dest, "wb") as fh:
            fh.write(data)
        os.chmod(dest, 0o644)

        _audit.info("logo_uploaded user=%s ip=%s file=%s bytes=%d", _user(), _client_ip(), filename, len(data))
        return jsonify({"path": dest, "filename": filename})

    @app.post("/api/reload-users")
    @auth.require_role("operator")
    def reload_users():
        """Recarga usuarios desde secrets.enc.yaml sin reiniciar el servicio."""
        try:
            new_users = secrets_store.load_users(secrets_path)
        except secrets_store.SecretsError as exc:
            _audit.error("reload_users_failed user=%s ip=%s error=%s", _user(), _client_ip(), exc)
            return jsonify({"error": str(exc)}), 500

        app.config["USERS"] = new_users
        _audit.info("reload_users_ok user=%s ip=%s count=%d", _user(), _client_ip(), len(new_users))
        return jsonify({"status": "ok", "users": len(new_users)})

    @app.get("/")
    def index():
        resp = send_from_directory(STATIC_DIR, "index.html")
        resp.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
        resp.headers["Pragma"] = "no-cache"
        resp.headers["Expires"] = "0"
        return resp

    return app
