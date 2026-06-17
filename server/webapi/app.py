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
import os
import time
from datetime import timedelta

from flask import Flask, Response, jsonify, request, send_from_directory, session, stream_with_context
from werkzeug.utils import secure_filename

from . import auth, config_store, device_detect, secrets_store, stream_control

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
LOGO_ALLOWED_EXT = {".png", ".jpg", ".jpeg"}
LOGO_MAX_BYTES = 5 * 1024 * 1024  # 5 MB


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
    logo_upload_dir = (test_config or {}).get(
        "LOGO_UPLOAD_DIR", os.environ.get("LOGO_UPLOAD_DIR", "/var/lib/raspi-streaming/assets/logos")
    )

    app.config.update(
        SECRET_KEY=secret_key,
        SESSION_COOKIE_SECURE=True,
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Strict",
        PERMANENT_SESSION_LIFETIME=timedelta(hours=12),
        STREAMING_ENV_PATH=streaming_env_path,
        LOGO_UPLOAD_DIR=logo_upload_dir,
    )

    if (test_config or {}).get("USERS") is not None:
        users = test_config["USERS"]
    else:
        users = secrets_store.load_users(secrets_path)
    app.config["USERS"] = users

    @app.get("/api/health")
    def health():
        return jsonify({"status": "ok"})

    @app.post("/api/login")
    def login():
        data = request.get_json(silent=True) or {}
        username = str(data.get("username", ""))
        password = str(data.get("password", ""))

        result = auth.login(app.config["USERS"], username, password)
        if result is None:
            return jsonify({"error": "Usuario o contraseña inválidos"}), 401

        return jsonify(result)

    @app.post("/api/logout")
    @auth.require_role("viewer")
    def logout():
        auth.logout()
        return jsonify({"status": "ok"})

    @app.get("/api/status")
    @auth.require_role("viewer")
    def status():
        return jsonify({svc: stream_control.status(svc) for svc in stream_control.SERVICES})

    @app.get("/api/events")
    @auth.require_role("viewer")
    def events():
        def generate():
            try:
                while True:
                    data = {svc: stream_control.status(svc) for svc in stream_control.SERVICES}
                    yield f"data: {json.dumps(data)}\n\n"
                    time.sleep(5)
            except GeneratorExit:
                pass
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
        return jsonify(validated)

    @app.post("/api/stream/<service>/start")
    @auth.require_role("operator")
    def stream_start(service):
        try:
            return jsonify(stream_control.start(service))
        except stream_control.StreamControlError as exc:
            return jsonify({"error": str(exc)}), 400

    @app.post("/api/stream/<service>/stop")
    @auth.require_role("operator")
    def stream_stop(service):
        try:
            return jsonify(stream_control.stop(service))
        except stream_control.StreamControlError as exc:
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

        # Leer primero para validar tamaño sin guardar en disco
        data = f.read(LOGO_MAX_BYTES + 1)
        if len(data) > LOGO_MAX_BYTES:
            return jsonify({"error": "Archivo demasiado grande (máx. 5 MB)"}), 400

        upload_dir = app.config["LOGO_UPLOAD_DIR"]
        os.makedirs(upload_dir, mode=0o755, exist_ok=True)

        filename = secure_filename(f.filename)
        dest = os.path.join(upload_dir, filename)
        with open(dest, "wb") as fh:
            fh.write(data)
        os.chmod(dest, 0o644)

        return jsonify({"path": dest, "filename": filename})

    @app.get("/")
    def index():
        return send_from_directory(STATIC_DIR, "index.html")

    return app
