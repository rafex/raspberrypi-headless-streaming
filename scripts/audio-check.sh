#!/usr/bin/env bash
# Detecta dispositivos de audio disponibles en la Raspberry Pi y verifica
# que el micrófono USB está funcionando correctamente.
# Muestra el índice de dispositivo ALSA necesario para los demás scripts.
#
# Uso:
#   ./audio-check.sh [opciones]
#
# Opciones:
#   --list          Listar todos los dispositivos de captura (default)
#   --test DEV      Grabar 3s desde el dispositivo y reproducir para verificar
#   --level DEV     Mostrar nivel de señal en tiempo real (VU meter en terminal)
#   --default       Mostrar el dispositivo de captura configurado como default
#   --set-default D Configurar dispositivo D como default en ~/.asoundrc
#   --help          Mostrar esta ayuda
#
# Formato del dispositivo ALSA:
#   hw:CARD,DEV     ej: hw:1,0  (tarjeta 1, dispositivo 0)
#   plughw:CARD,DEV ej: plughw:1,0  (con conversión de formato automática)
#
# Ejemplos:
#   ./audio-check.sh
#   ./audio-check.sh --test hw:1,0
#   ./audio-check.sh --level hw:1,0
#   ./audio-check.sh --set-default hw:1,0
#
# Tip: Los micrófonos USB suelen aparecer como hw:1,0 o hw:2,0
#      ya que hw:0,0 es generalmente el audio HDMI/analógico de la Pi.

set -euo pipefail

MODE="list"
DEVICE=""

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)        MODE="list"; shift ;;
        --test)        MODE="test"; DEVICE="$2"; shift 2 ;;
        --level)       MODE="level"; DEVICE="$2"; shift 2 ;;
        --default)     MODE="default"; shift ;;
        --set-default) MODE="set-default"; DEVICE="$2"; shift 2 ;;
        --help)        usage ;;
        *) die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
    esac
done

command -v arecord >/dev/null 2>&1 || die "arecord no encontrado. Instalar con: sudo apt install alsa-utils"
command -v aplay   >/dev/null 2>&1 || die "aplay no encontrado. Instalar con: sudo apt install alsa-utils"

# ---------------------------------------------------------------------------
# Modo: listar dispositivos
# ---------------------------------------------------------------------------
if [[ "$MODE" == "list" ]]; then
    echo "=== Dispositivos de captura (micrófonos) ==="
    echo ""
    arecord -l 2>/dev/null || echo "  (ninguno detectado)"
    echo ""

    echo "=== Dispositivos de reproducción ==="
    echo ""
    aplay -l 2>/dev/null || echo "  (ninguno detectado)"
    echo ""

    echo "=== Identificar micrófono USB ==="
    echo ""
    if arecord -l 2>/dev/null | grep -qi "usb\|microphone\|mic\|webcam\|boya\|boyalink\|lavalier\|wireless\|focusrite\|scarlett"; then
        echo "Dispositivos USB detectados:"
        arecord -l 2>/dev/null | grep -i "usb\|microphone\|mic\|webcam\|boya\|boyalink\|lavalier\|wireless\|focusrite\|scarlett" || true
        echo ""
        echo "Para usar el micrófono USB en los scripts, usar la forma hw:CARD,DEV"
        echo "donde CARD es el número de 'card' y DEV el de 'device' en la lista."
        echo ""
        echo "Ejemplo: si aparece 'card 1: Device [USB PnP ...], device 0:'"
        echo "  → usar hw:1,0 o plughw:1,0"
    else
        echo "No se detectaron dispositivos USB explícitamente."
        echo "Conectar el micrófono USB y ejecutar de nuevo."
        echo ""
        echo "Dispositivos disponibles para captura:"
        arecord -l 2>/dev/null | grep "^card" || echo "  (ninguno)"
    fi

    echo ""
    echo "=== Comandos útiles ==="
    echo "  Verificar señal  : ./audio-check.sh --level hw:1,0"
    echo "  Probar grabación : ./audio-check.sh --test hw:1,0"
    echo "  Configurar default: ./audio-check.sh --set-default hw:1,0"
    exit 0
fi

# ---------------------------------------------------------------------------
# Modo: verificar dispositivo default
# ---------------------------------------------------------------------------
if [[ "$MODE" == "default" ]]; then
    echo "=== Dispositivo de captura default ==="
    echo ""

    if [[ -f ~/.asoundrc ]]; then
        echo "Configuración en ~/.asoundrc:"
        cat ~/.asoundrc
    elif [[ -f /etc/asound.conf ]]; then
        echo "Configuración en /etc/asound.conf:"
        cat /etc/asound.conf
    else
        echo "No hay configuración ALSA personalizada."
        echo "El dispositivo default es hw:0,0 (audio interno de la Pi)."
        echo ""
        echo "Para cambiar el default: ./audio-check.sh --set-default hw:1,0"
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# Modo: configurar dispositivo default
# ---------------------------------------------------------------------------
if [[ "$MODE" == "set-default" ]]; then
    [[ -n "$DEVICE" ]] || die "Especificar dispositivo. Ej: --set-default hw:1,0"

    # Extraer card number del dispositivo (hw:CARD,DEV o plughw:CARD,DEV)
    CARD_NUM=$(echo "$DEVICE" | grep -oE 'hw:[0-9]+' | grep -oE '[0-9]+' || true)
    [[ -n "$CARD_NUM" ]] || die "Formato de dispositivo inválido: $DEVICE. Usar hw:N,N"

    echo "Configurando micrófono USB como dispositivo default..."
    echo "Dispositivo: ${DEVICE} (card ${CARD_NUM})"
    echo ""

    cat > ~/.asoundrc <<EOF
# Configuración ALSA generada por audio-check.sh
# Micrófono USB como dispositivo de captura default

pcm.!default {
    type asym
    capture.pcm "mic"
    playback.pcm "speaker"
}

pcm.mic {
    type plug
    slave {
        pcm "hw:${CARD_NUM},0"
    }
}

pcm.speaker {
    type plug
    slave {
        pcm "hw:0,0"
    }
}

ctl.!default {
    type hw
    card ${CARD_NUM}
}
EOF

    echo "Configuración guardada en ~/.asoundrc"
    echo ""
    echo "Para aplicar globalmente (todos los usuarios):"
    echo "  sudo cp ~/.asoundrc /etc/asound.conf"
    echo ""
    echo "Verificar: arecord -d 3 -f cd /tmp/test.wav && aplay /tmp/test.wav"
    exit 0
fi

# Para los modos que requieren dispositivo
[[ -n "$DEVICE" ]] || die "Especificar dispositivo ALSA. Ej: hw:1,0 o plughw:1,0"

# ---------------------------------------------------------------------------
# Modo: probar grabación
# ---------------------------------------------------------------------------
if [[ "$MODE" == "test" ]]; then
    TMPFILE=$(mktemp /tmp/audio-test-XXXXXX.wav)
    trap "rm -f $TMPFILE" EXIT

    echo "=== Prueba de grabación ==="
    echo "  Dispositivo : ${DEVICE}"
    echo "  Duración    : 3 segundos"
    echo ""
    echo "Grabando... habla cerca del micrófono."

    arecord \
        --device="$DEVICE" \
        --duration=3 \
        --format=cd \
        --quiet \
        "$TMPFILE" 2>/dev/null \
    && echo "Grabación completada. Reproduciendo..." \
    || die "Fallo en grabación. Verificar dispositivo: ${DEVICE}"

    aplay --quiet "$TMPFILE" 2>/dev/null \
    && echo "Reproducción completada." \
    || echo "AVISO: fallo en reproducción (normal si no hay altavoz)."

    SIZE=$(du -sh "$TMPFILE" | cut -f1)
    echo ""
    echo "Archivo grabado: ${SIZE} (3s WAV CD quality)"
    echo ""
    echo "Si escuchaste el audio, el micrófono ${DEVICE} funciona correctamente."
    exit 0
fi

# ---------------------------------------------------------------------------
# Modo: nivel de señal en tiempo real
# ---------------------------------------------------------------------------
if [[ "$MODE" == "level" ]]; then
    command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg requerido para mostrar niveles. Instalar con: sudo apt install ffmpeg"

    echo "=== Nivel de señal del micrófono ==="
    echo "  Dispositivo : ${DEVICE}"
    echo "  Ctrl+C para salir"
    echo ""
    echo "Mostrando nivel de audio en tiempo real..."
    echo "(La barra debe subir cuando hablas cerca del micrófono)"
    echo ""

    # ffmpeg captura audio y muestra volumedetect en tiempo real
    # silencedetect muestra cuándo hay señal y cuándo hay silencio
    ffmpeg \
        -hide_banner \
        -f alsa \
        -i "$DEVICE" \
        -af "volumedetect,silencedetect=noise=-30dB:duration=0.5" \
        -f null \
        - 2>&1 \
    | grep --line-buffered -E "mean_volume|max_volume|silence_(start|end)" \
    | awk '{
        if (/mean_volume/) {
            gsub(/.*mean_volume: /, ""); gsub(/ dB.*/, "");
            vol = $0 + 60;
            bar = "";
            for (i = 0; i < vol; i++) bar = bar "█";
            printf "\r  Señal: [%-60s] %s dB    ", bar, $0;
            fflush();
        }
        if (/silence_start/) print "\n  [silencio]";
        if (/silence_end/)   print "\n  [señal detectada]";
    }'

    exit 0
fi
