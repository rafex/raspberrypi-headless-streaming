#!/usr/bin/env bash
# Genera assets de ejemplo (logo y frame) usando ffmpeg.
# Útil para probar overlays sin tener archivos PNG propios.
#
# Uso:
#   ./generate-assets.sh
#
# Genera:
#   assets/logo.png   — logo de ejemplo 200x80 px con texto "LIVE"
#   assets/frame.png  — marco transparente 1920x1080 con bordes de color

set -euo pipefail

ASSETS_DIR="$(cd "$(dirname "$0")/../assets" && pwd)"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg no encontrado. Instalar con: sudo apt install ffmpeg"

echo "Generando assets en: ${ASSETS_DIR}"

# --- Logo: fondo negro semitransparente con texto LIVE ---
ffmpeg -y \
    -f lavfi \
    -i "color=c=black@0.6:size=200x80:rate=1" \
    -frames:v 1 \
    -vf "drawtext=text='● LIVE':fontcolor=white:fontsize=28:x=(w-text_w)/2:y=(h-text_h)/2:box=0" \
    "${ASSETS_DIR}/logo.png" \
    -loglevel warning

echo "  ✓ assets/logo.png"

# --- Frame: imagen 1920x1080 completamente transparente con bordes de color ---
# Se genera un PNG con un borde de 8px de color rojo semitransparente
ffmpeg -y \
    -f lavfi \
    -i "color=c=0x00000000:size=1920x1080:rate=1" \
    -frames:v 1 \
    -vf "
        drawbox=x=0:y=0:w=iw:h=8:color=red@0.8:t=fill,
        drawbox=x=0:y=ih-8:w=iw:h=8:color=red@0.8:t=fill,
        drawbox=x=0:y=0:w=8:h=ih:color=red@0.8:t=fill,
        drawbox=x=iw-8:y=0:w=8:h=ih:color=red@0.8:t=fill
    " \
    "${ASSETS_DIR}/frame.png" \
    -loglevel warning

echo "  ✓ assets/frame.png"
echo ""
echo "Assets generados correctamente."
echo "Reemplázalos con tus propios archivos PNG para personalizar el stream."
