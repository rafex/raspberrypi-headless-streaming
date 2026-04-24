# Overlays

Referencia de filtros ffmpeg para overlays de video en el pipeline headless.

---

## Consideración importante: re-encoding

El stream básico usa `vcodec copy` — el H264 del hardware se reenvía sin tocar.

En cuanto se aplica cualquier overlay, ffmpeg debe:

1. **Decodificar** el H264 a frames en crudo (CPU)
2. **Aplicar filtros** sobre los frames (CPU)
3. **Re-codificar** con `libx264` (CPU)

En la Pi 3B esto incrementa el uso de CPU significativamente.

| Modo | Encoding | CPU aproximado |
|---|---|---|
| Sin overlay | hardware H264 copy | ~20–30% |
| 1 overlay simple | libx264 veryfast | ~60–75% |
| 2–3 overlays | libx264 veryfast | ~80–95% |
| 4+ overlays | libx264 veryfast | posible saturación |

**Recomendación para Pi 3B:** máximo 2 overlays combinados con preset `veryfast`.

---

## Posiciones disponibles

Todas las posiciones en `stream-overlay.sh` usan estos códigos:

| Código | Posición |
|---|---|
| `tl` | arriba izquierda (top-left) |
| `tr` | arriba derecha (top-right) |
| `bl` | abajo izquierda (bottom-left) |
| `br` | abajo derecha (bottom-right) |
| `center` | centro de pantalla |

---

## Overlay 1: Logo PNG

Superpone una imagen PNG sobre el video.

```bash
./stream-overlay.sh -u rtmp://... \
    --logo assets/logo.png \
    --logo-pos br \
    --logo-pad 20
```

Filtro ffmpeg equivalente:

```
[0:v][1:v]overlay=W-w-20:H-h-20
```

### Posiciones de referencia rápida

| `--logo-pos` | Expresión ffmpeg |
|---|---|
| `tl` | `overlay=20:20` |
| `tr` | `overlay=W-w-20:20` |
| `bl` | `overlay=20:H-h-20` |
| `br` | `overlay=W-w-20:H-h-20` |
| `center` | `overlay=(W-w)/2:(H-h)/2` |

### Assets recomendados para logo

- Formato: PNG con canal alpha (transparencia)
- Tamaño recomendado: entre 100x40 y 300x120 px
- Fondo transparente para que no tape el video

---

## Overlay 2: Marco PNG (fullscreen frame)

Superpone un PNG del mismo tamaño que el video (1920x1080) con transparencia en el centro.

```bash
./stream-overlay.sh -u rtmp://... \
    --frame assets/frame.png
```

Filtro ffmpeg equivalente:

```
[0:v][1:v]overlay=0:0
```

### Crear un marco personalizado

El marco debe ser un PNG 1920x1080 con:
- Bordes opacos o semitransparentes con el diseño deseado
- Centro completamente transparente (alpha=0) para que se vea el video

Generar marco de ejemplo con ffmpeg:

```bash
ffmpeg -f lavfi -i "color=c=0x00000000:size=1920x1080:rate=1" \
    -frames:v 1 \
    -vf "
        drawbox=x=0:y=0:w=iw:h=12:color=red@0.9:t=fill,
        drawbox=x=0:y=ih-12:w=iw:h=12:color=red@0.9:t=fill,
        drawbox=x=0:y=0:w=12:h=ih:color=red@0.9:t=fill,
        drawbox=x=iw-12:y=0:w=12:h=ih:color=red@0.9:t=fill
    " frame.png
```

---

## Overlay 3: Texto estático

Texto fijo que aparece durante todo el stream.

```bash
./stream-overlay.sh -u rtmp://... \
    --text "Raspi Streaming Demo" \
    --text-pos bl
```

Filtro ffmpeg equivalente:

```
drawtext=text='Raspi Streaming Demo':fontcolor=white:fontsize=24:x=20:y=h-text_h-20:box=1:boxcolor=black@0.5:boxborderw=6
```

### Opciones de texto

| Parámetro ffmpeg | Descripción |
|---|---|
| `text='...'` | texto a mostrar |
| `fontcolor=white` | color del texto |
| `fontsize=24` | tamaño en px |
| `x=`, `y=` | posición |
| `box=1` | caja de fondo |
| `boxcolor=black@0.5` | color de caja con 50% opacidad |
| `boxborderw=6` | padding interno de la caja |

---

## Overlay 4: Timestamp dinámico

Muestra la hora actual en tiempo real sobre el video.

```bash
./stream-overlay.sh -u rtmp://... \
    --timestamp
```

Filtro ffmpeg equivalente:

```
drawtext=text='%{localtime\:%Y-%m-%d %H\:%M\:%S}':fontcolor=white:fontsize=20:x=10:y=10:box=1:boxcolor=black@0.5:boxborderw=5
```

El formato `%{localtime\:...}` usa la hora del sistema en tiempo real.

---

## Combinaciones recomendadas

### Logo + Timestamp (recomendado para Pi 3B)

```bash
./stream-overlay.sh -u rtmp://... \
    --logo assets/logo.png --logo-pos tr \
    --timestamp
```

CPU estimado en Pi 3B: ~65–75%

### Marco + Texto de identificación

```bash
./stream-overlay.sh -u rtmp://... \
    --frame assets/frame.png \
    --text "Cámara 1 — Entrada Principal" --text-pos bl
```

CPU estimado en Pi 3B: ~70–80%

### Todo combinado (solo para Pi 4B)

```bash
./stream-overlay.sh -u rtmp://... \
    --logo assets/logo.png --logo-pos br \
    --frame assets/frame.png \
    --text "Sala de servidores" --text-pos bl \
    --timestamp
```

CPU estimado en Pi 3B: ~90–100% — **no recomendado**
CPU estimado en Pi 4B: ~50–65% — funcional

---

## Presets libx264

El preset controla velocidad vs calidad del re-encoding.  
En la Pi 3B usar `veryfast` o `superfast`.

| Preset | Velocidad | Calidad | CPU |
|---|---|---|---|
| `ultrafast` | máxima | menor | mínimo |
| `superfast` | muy alta | baja | muy bajo |
| `veryfast` | alta | media | bajo — **recomendado Pi 3B** |
| `faster` | media-alta | media-alta | moderado |
| `fast` | media | buena | moderado-alto |
| `medium` | media | buena | alto — **no usar en Pi 3B** |

Cambiar preset:

```bash
./stream-overlay.sh -u rtmp://... --logo assets/logo.png --preset superfast
```

---

## Monitorear CPU y temperatura durante streaming

En otra terminal de la Pi:

```bash
# CPU y procesos
top

# Temperatura del SoC
vcgencmd measure_temp

# Ver throttling (si la Pi está limitando por temperatura)
vcgencmd get_throttled
```

Si `get_throttled` devuelve `0x50005` o similar, la Pi está en throttling térmico.  
Solución: reducir bitrate, cambiar a `superfast`, o añadir disipador.
