"""
Servidor HTTP de análisis de video con IA para Raspberry Pi 4B.

Acepta frames JPEG (base64) y eventos desde la Pi 3B y los analiza
usando DeepSeek o OpenRouter según la configuración.

Uso:
    python analyze-server.py [opciones]

Opciones:
    --provider  deepseek|openrouter  (default: openrouter)
    --model     nombre del modelo    (usa el default del proveedor si no se especifica)
    --host      IP donde escuchar    (default: 0.0.0.0)
    --port      puerto               (default: 8080)
    --prompt    prompt del sistema   (default: el built-in)

Variables de entorno:
    AI_PROVIDER          deepseek | openrouter
    AI_MODEL             nombre del modelo a usar
    DEEPSEEK_API_KEY     API key de DeepSeek
    OPENROUTER_API_KEY   API key de OpenRouter
    SERVER_HOST          IP de escucha
    SERVER_PORT          Puerto

Ejemplos:
    AI_PROVIDER=deepseek DEEPSEEK_API_KEY=sk-... python analyze-server.py
    AI_PROVIDER=openrouter OPENROUTER_API_KEY=sk-or-... python analyze-server.py
    python analyze-server.py --provider openrouter --model google/gemini-flash-1.5-8b

Modelos recomendados:
    DeepSeek:
        deepseek-vl-7b-chat      (visión, 7B, rápido)
        deepseek-vl-67b-chat     (visión, 67B, más preciso)
        deepseek-chat            (solo texto, sin visión)

    OpenRouter (con visión):
        google/gemini-flash-1.5-8b         (rápido, barato)
        google/gemini-flash-1.5            (balance)
        meta-llama/llama-3.2-11b-vision-instruct  (open source)
        anthropic/claude-3-haiku           (rápido)
        openai/gpt-4o-mini                 (equilibrado)
"""

import argparse
import base64
import logging
import os
import sys
from datetime import datetime

from flask import Flask, jsonify, request
from openai import OpenAI

# ---------------------------------------------------------------------------
# Configuración de proveedores
# ---------------------------------------------------------------------------

PROVIDERS = {
    "deepseek": {
        "base_url": "https://api.deepseek.com/v1",
        "env_key": "DEEPSEEK_API_KEY",
        "default_model": "deepseek-chat",
        "vision_models": ["deepseek-vl-7b-chat", "deepseek-vl-67b-chat"],
        "label": "DeepSeek",
    },
    "openrouter": {
        "base_url": "https://openrouter.ai/api/v1",
        "env_key": "OPENROUTER_API_KEY",
        "default_model": "google/gemini-flash-1.5-8b",
        "vision_models": [
            "google/gemini-flash-1.5-8b",
            "google/gemini-flash-1.5",
            "meta-llama/llama-3.2-11b-vision-instruct",
            "anthropic/claude-3-haiku",
            "openai/gpt-4o-mini",
        ],
        "label": "OpenRouter",
    },
}

DEFAULT_SYSTEM_PROMPT = (
    "Eres un sistema de análisis de video para seguridad. "
    "Cuando recibas una imagen, describe brevemente (2-3 oraciones) lo que ves. "
    "Indica si hay personas, objetos sospechosos, movimiento relevante o situaciones de seguridad. "
    "Si se proporciona contexto adicional (como eventos de red), correlalos con lo que ves. "
    "Responde siempre en español."
)

# ---------------------------------------------------------------------------
# Argparse y configuración
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(description="Servidor de análisis IA para Raspberry Pi")
    parser.add_argument("--provider", choices=["deepseek", "openrouter"],
                        default=os.environ.get("AI_PROVIDER", "openrouter"))
    parser.add_argument("--model", default=os.environ.get("AI_MODEL", ""))
    parser.add_argument("--host", default=os.environ.get("SERVER_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("SERVER_PORT", 8080)))
    parser.add_argument("--prompt", default=DEFAULT_SYSTEM_PROMPT)
    parser.add_argument("--debug", action="store_true")
    return parser.parse_args()


def build_client(provider_name: str) -> tuple[OpenAI, str, dict]:
    """Construye el cliente OpenAI para el proveedor elegido."""
    config = PROVIDERS[provider_name]
    api_key = os.environ.get(config["env_key"], "")

    if not api_key:
        print(f"ERROR: variable de entorno {config['env_key']} no definida.", file=sys.stderr)
        sys.exit(1)

    extra_headers = {}
    if provider_name == "openrouter":
        extra_headers = {
            "HTTP-Referer": "https://github.com/rafex/raspberrypi-headless-streaming",
            "X-Title": "RaspiHeadlessStreaming",
        }

    client = OpenAI(
        api_key=api_key,
        base_url=config["base_url"],
        default_headers=extra_headers,
    )
    return client, config, extra_headers


# ---------------------------------------------------------------------------
# Construcción del mensaje al LLM
# ---------------------------------------------------------------------------

def build_messages(system_prompt: str, context: str, frame_b64: str, model: str, config: dict) -> list:
    """
    Construye el array de mensajes según si el modelo soporta visión.
    Si hay frame y el modelo está en la lista de vision_models, envía la imagen.
    Si no, solo envía texto con el contexto.
    """
    user_text = context if context else "Analiza la situación actual."

    has_vision = any(vm in model for vm in config["vision_models"]) or \
                 any(vm == model for vm in config["vision_models"])

    if frame_b64 and has_vision:
        content = [
            {
                "type": "image_url",
                "image_url": {
                    "url": f"data:image/jpeg;base64,{frame_b64}",
                    "detail": "low",
                },
            },
            {
                "type": "text",
                "text": user_text,
            },
        ]
    else:
        if frame_b64 and not has_vision:
            user_text = f"[Frame recibido pero modelo sin visión] {user_text}"
        content = user_text

    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": content},
    ]


# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------

def create_app(client: OpenAI, model: str, config: dict, system_prompt: str) -> Flask:
    app = Flask(__name__)
    log = logging.getLogger("analyze-server")

    @app.route("/health", methods=["GET"])
    def health():
        return jsonify({
            "status": "ok",
            "provider": config["label"],
            "model": model,
            "timestamp": datetime.now().isoformat(),
        })

    @app.route("/analyze", methods=["POST"])
    def analyze():
        data = request.get_json(silent=True)
        if not data:
            return jsonify({"error": "Payload JSON requerido"}), 400

        event = data.get("event", "unknown")
        source = data.get("source", "unknown")
        context = data.get("context", "")
        frame_b64 = data.get("frame", "")
        timestamp = data.get("timestamp", datetime.now().isoformat())

        log.info("← evento=%s source=%s frame=%s context=%s",
                 event, source, "sí" if frame_b64 else "no", context[:60])

        # Enriquecer el contexto con metadatos del evento
        full_context = f"Evento: {event}. Fuente: {source}. Timestamp: {timestamp}."
        if context:
            full_context += f" Contexto: {context}"

        messages = build_messages(system_prompt, full_context, frame_b64, model, config)

        try:
            response = client.chat.completions.create(
                model=model,
                messages=messages,
                max_tokens=300,
                temperature=0.3,
            )
            analysis = response.choices[0].message.content.strip()
            tokens_used = response.usage.total_tokens if response.usage else 0

        except Exception as exc:
            log.error("Error llamando a %s: %s", config["label"], exc)
            return jsonify({"error": str(exc)}), 502

        log.info("→ análisis (%d tokens): %s", tokens_used, analysis[:80])

        return jsonify({
            "analysis": analysis,
            "provider": config["label"],
            "model": model,
            "event": event,
            "source": source,
            "tokens": tokens_used,
            "timestamp": datetime.now().isoformat(),
        })

    @app.route("/event", methods=["POST"])
    def event_only():
        """Endpoint para eventos de texto sin frame (eventos de red, alertas, etc.)."""
        data = request.get_json(silent=True)
        if not data:
            return jsonify({"error": "Payload JSON requerido"}), 400

        # Reutilizar /analyze sin frame
        data["frame"] = ""
        request._cached_json = (data, data)
        return analyze()

    return app


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    args = parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )
    log = logging.getLogger("analyze-server")

    provider_name = args.provider
    config = PROVIDERS[provider_name]
    model = args.model or config["default_model"]

    log.info("=== Servidor de análisis IA ===")
    log.info("  Proveedor : %s", config["label"])
    log.info("  Modelo    : %s", model)
    log.info("  Escuchando: %s:%d", args.host, args.port)
    log.info("  Endpoints : POST /analyze  POST /event  GET /health")

    client, config, _ = build_client(provider_name)
    app = create_app(client, model, config, args.prompt)

    app.run(host=args.host, port=args.port, debug=args.debug)


if __name__ == "__main__":
    main()
