#!/usr/bin/env bash
# Graba video + audio usando cámara USB y micrófono USB (BOYA / webcam).
# Detecta automáticamente los dispositivos conectados.
# Si no se especifica destino, guarda en /tmp.
#
# Uso:
#   ./rec.sh [opciones] [archivo_salida.mp4]
#
# Opciones:
#   -t SECONDS     Duración en segundos, 0 = indefinido (default: 0)
#   -w WIDTH       Ancho de video (default: 1280)
#   -h HEIGHT      Alto de video (default: 720)
#   -f FPS         Frames por segundo (default: 30)
#   -b BITRATE     Bitrate de video en bits/s (default: 2500000)
#   --cam DEV      Forzar dispositivo de cámara (ej: /dev/video0)
#   --mic DEV      Forzar dispositivo de micrófono (ej: plughw:1,0)
#   --mic-rate N   Sample rate del micrófono en Hz (default: autodetectado)
#   --mono         Capturar audio en mono — 1 canal (default)
#   --stereo       Capturar audio en estéreo — 2 canales
#   --audio-ch N   Número de canales explícito: 1 o 2 (default: 1)
#   --no-audio     Grabar solo video sin audio
#   --tmp          Guardar siempre en /tmp (aunque se pase nombre de archivo)
#   --help         Mostrar esta ayuda
#
# Ejemplos:
#   ./rec.sh                          # detecta todo, guarda en /tmp
#   ./rec.sh -t 30                    # 30 segundos, guarda en /tmp
#   ./rec.sh -t 60 grabacion.mp4      # 60 segundos, guarda en el directorio actual
#   ./rec.sh /home/pi/videos/demo.mp4 # guarda en ruta específica
#   ./rec.sh --cam /dev/video0 --mic plughw:1,0 --mono -t 30
#   ./rec.sh --stereo -t 60 demo.mp4

set -euo pipefail

# ---------------------------------------------------------------------------
# Valores por defecto
# ---------------------------------------------------------------------------
DURATION=0
WIDTH=1280
HEIGHT=720
FPS=30
BITRATE=2500000
CAM_DEV=""
MIC_DEV=""
MIC_RATE=0          # 0 = autodetectar según el micrófono encontrado
MIC_CH=1            # 1 = mono (default), 2 = stereo
NO_AUDIO=false
FORCE_TMP=false
OUTPUT=""

usage() {
    grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
    exit 0
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Parsear argumentos
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -t)          DURATION="$2";  shift 2 ;;
        -w)          WIDTH="$2";     shift 2 ;;
        -h)          HEIGHT="$2";    shift 2 ;;
        -f)          FPS="$2";       shift 2 ;;
        -b)          BITRATE="$2";   shift 2 ;;
        --cam)       CAM_DEV="$2";   shift 2 ;;
        --mic)       MIC_DEV="$2";   shift 2 ;;
        --mic-rate)  MIC_RATE="$2";  shift 2 ;;
        --mono)      MIC_CH=1;       shift ;;
        --stereo)    MIC_CH=2;       shift ;;
        --audio-ch)  MIC_CH="$2";    shift 2 ;;
        --no-audio)  NO_AUDIO=true;  shift ;;
        --tmp)       FORCE_TMP=true; shift ;;
        --help)      usage ;;
        -*)          die "Opción desconocida: $1. Usa --help para ver las opciones." ;;
        *)           OUTPUT="$1";    shift ;;   # argumento posicional = archivo de salida
    esac
done

command -v ffmpeg    >/dev/null 2>&1 || die "ffmpeg no encontrado. Instalar: sudo apt install ffmpeg"
command -v v4l2-ctl  >/dev/null 2>&1 || die "v4l2-ctl no encontrado. Instalar: sudo apt install v4l-utils"

# ---------------------------------------------------------------------------
# Detectar cámara USB
# ---------------------------------------------------------------------------
detect_camera() {
    for dev in /dev/video0 /dev/video1 /dev/video2 /dev/video3; do
        [[ -e "$dev" ]] || continue
        if v4l2-ctl --device="$dev" --list-formats 2>/dev/null \
                | grep -qE "MJPG|MJPEG|YUYV|H264"; then
            echo "$dev"
            return 0
        fi
    done
    return 1
}

# Detectar si el dispositivo soporta MJPEG (más eficiente que YUYV en USB)
supports_mjpeg() {
    local dev="$1"
    v4l2-ctl --device="$dev" --list-formats 2>/dev/null | grep -qE "MJPG|MJPEG"
}

# ---------------------------------------------------------------------------
# Detectar micrófono USB (prefiere BOYA sobre micrófono integrado de webcam)
# ---------------------------------------------------------------------------
detect_mic() {
    local best_dev=""
    local best_rate=44100
    local best_priority=0

    while IFS= read -r line; do
        [[ "$line" =~ ^card ]] || continue
        local card_num dev_num card_name

        card_num=$(echo "$line" | grep -oE 'card [0-9]+'  | grep -oE '[0-9]+')
        dev_num=$(echo  "$line" | grep -oE 'device [0-9]+' | grep -oE '[0-9]+')
        card_name=$(echo "$line" | grep -oE '\[[^]]+\]' | head -1 | tr -d '[]')

        local dev="plughw:${card_num},${dev_num}"
        local priority=1

        # Prioridad más alta para BOYA (inalámbrico dedicado)
        if echo "$card_name" | grep -qi "boya\|boyalink"; then
            priority=10
            best_rate=48000
        # Prioridad media para Focusrite
        elif echo "$card_name" | grep -qi "focusrite\|scarlett"; then
            priority=8
            best_rate=48000
        # Prioridad baja para micrófono integrado de webcam
        elif echo "$card_name" | grep -qi "c920\|c922\|c910\|webcam\|logitech"; then
            priority=2
        fi

        if [[ "$priority" -gt "$best_priority" ]]; then
            best_priority="$priority"
            best_dev="$dev"
        fi
    done < <(arecord -l 2>/dev/null || true)

    echo "${best_dev}:${best_rate}"
}

# ---------------------------------------------------------------------------
# Resolver cámara
# ---------------------------------------------------------------------------
echo ""
echo "=== Detectando dispositivos ==="
echo ""

if [[ -z "$CAM_DEV" ]]; then
    CAM_DEV=$(detect_camera || true)
    [[ -n "$CAM_DEV" ]] || die "No se detectó ninguna cámara USB en /dev/video*.\n       Conectar la cámara y verificar con: scripts/usb-camera.sh --list"
    CAM_NAME=$(v4l2-ctl --device="$CAM_DEV" --info 2>/dev/null \
        | grep "Card type" | sed 's/.*: //' | xargs || echo "Cámara USB")
    echo "  [✓] Cámara   : $CAM_NAME ($CAM_DEV)"
else
    [[ -e "$CAM_DEV" ]] || die "Dispositivo no encontrado: $CAM_DEV"
    CAM_NAME=$(v4l2-ctl --device="$CAM_DEV" --info 2>/dev/null \
        | grep "Card type" | sed 's/.*: //' | xargs || echo "$CAM_DEV")
    echo "  [✓] Cámara   : $CAM_NAME ($CAM_DEV) [forzado]"
fi

# Elegir formato de entrada: MJPEG si está disponible (menor CPU, mejor FPS)
if supports_mjpeg "$CAM_DEV"; then
    INPUT_FORMAT="mjpeg"
    INPUT_FORMAT_LABEL="MJPEG"
else
    INPUT_FORMAT="yuyv422"
    INPUT_FORMAT_LABEL="YUYV"
fi

# ---------------------------------------------------------------------------
# Resolver micrófono
# ---------------------------------------------------------------------------
if [[ "$NO_AUDIO" == false ]]; then
    if [[ -z "$MIC_DEV" ]]; then
        DETECTED=$(detect_mic)
        MIC_DEV="${DETECTED%%:*}"          # todo antes del último :
        AUTO_RATE="${DETECTED##*:}"        # todo después del último :

        if [[ -z "$MIC_DEV" ]]; then
            echo "  [!] Micrófono: no detectado — grabando sin audio"
            NO_AUDIO=true
        else
            [[ "$MIC_RATE" -eq 0 ]] && MIC_RATE="$AUTO_RATE"
            CARD_NUM=$(echo "$MIC_DEV" | grep -oE '[0-9]+' | head -1)
            MIC_NAME=$(arecord -l 2>/dev/null \
                | grep "^card ${CARD_NUM}:" \
                | grep -oE '\[[^]]+\]' | head -1 | tr -d '[]' || echo "$MIC_DEV")
            echo "  [✓] Micrófono: $MIC_NAME ($MIC_DEV — ${MIC_RATE}Hz) [autodetectado]"
        fi
    else
        [[ "$MIC_RATE" -eq 0 ]] && MIC_RATE=44100
        echo "  [✓] Micrófono: $MIC_DEV — ${MIC_RATE}Hz [forzado]"
    fi
fi

# ---------------------------------------------------------------------------
# Resolver archivo de salida
# ---------------------------------------------------------------------------
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

if [[ -z "$OUTPUT" || "$FORCE_TMP" == true ]]; then
    OUTPUT="/tmp/rec_${TIMESTAMP}.mp4"
elif [[ "$OUTPUT" != */* ]]; then
    # Solo nombre de archivo sin ruta → guardar en /tmp/
    OUTPUT="/tmp/$OUTPUT"
fi
# Asegurar extensión .mp4
[[ "$OUTPUT" == *.mp4 ]] || OUTPUT="${OUTPUT%.mkv}.mp4"

# Asegurar que el directorio de destino existe
OUTPUT_DIR="$(dirname "$OUTPUT")"
[[ -d "$OUTPUT_DIR" ]] || die "Directorio de destino no existe: $OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Mostrar resumen antes de grabar
# ---------------------------------------------------------------------------
echo ""
echo "=== Grabando ==="
echo ""
echo "  Resolución : ${WIDTH}x${HEIGHT} @ ${FPS}fps"
echo "  Formato    : $INPUT_FORMAT_LABEL → H264 (libx264 ultrafast)"
echo "  Bitrate    : $((BITRATE / 1000)) kbps"
if [[ "$NO_AUDIO" == true ]]; then
    echo "  Audio      : deshabilitado"
else
    CH_LABEL="mono"
    [[ "$MIC_CH" -eq 2 ]] && CH_LABEL="stereo"
    echo "  Audio      : $MIC_DEV — ${MIC_RATE}Hz ${CH_LABEL}"
fi
if [[ "$DURATION" -eq 0 ]]; then
    echo "  Duración   : indefinida — Ctrl+C para detener"
else
    echo "  Duración   : ${DURATION}s"
fi
echo "  Salida     : $OUTPUT"
echo ""

# ---------------------------------------------------------------------------
# Construir argumentos
# ---------------------------------------------------------------------------
DURATION_ARGS=()
[[ "$DURATION" -gt 0 ]] && DURATION_ARGS=(-t "$DURATION")

AUDIO_ARGS=()
if [[ "$NO_AUDIO" == false ]]; then
    AUDIO_ARGS=(
        -f alsa
        -ar "$MIC_RATE"
        -ac "$MIC_CH"
        -i "$MIC_DEV"
        -acodec aac
        -b:a 128k
    )
else
    AUDIO_ARGS=(-an)
fi

# ---------------------------------------------------------------------------
# Grabar
# ---------------------------------------------------------------------------
ffmpeg \
    -hide_banner \
    -loglevel warning \
    -stats \
    -f v4l2 \
    -input_format "$INPUT_FORMAT" \
    -video_size "${WIDTH}x${HEIGHT}" \
    -framerate "$FPS" \
    -i "$CAM_DEV" \
    "${AUDIO_ARGS[@]}" \
    "${DURATION_ARGS[@]}" \
    -vcodec libx264 \
    -preset ultrafast \
    -b:v "$BITRATE" \
    -movflags +faststart \
    "$OUTPUT"

# ---------------------------------------------------------------------------
# Resultado
# ---------------------------------------------------------------------------
echo ""
if [[ -f "$OUTPUT" ]]; then
    SIZE=$(du -sh "$OUTPUT" | cut -f1)
    echo "  [✓] Grabación guardada: $OUTPUT ($SIZE)"

    # Mostrar duración real si ffprobe está disponible
    if command -v ffprobe >/dev/null 2>&1; then
        REAL_DUR=$(ffprobe -v quiet -show_entries format=duration \
            -of default=noprint_wrappers=1:nokey=1 "$OUTPUT" 2>/dev/null \
            | awk '{printf "%.1fs", $1}' || echo "?")
        echo "  [✓] Duración real   : $REAL_DUR"
    fi
else
    echo "  [!] El archivo no se generó. Revisar errores arriba."
fi
echo ""
