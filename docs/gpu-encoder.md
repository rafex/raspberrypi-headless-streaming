# Encoder GPU — h264_v4l2m2m (VideoCore H.264)

Referencia para activar el encoder de hardware H.264 del VideoCore en Raspberry Pi 3B/4B y entender cuándo conviene usarlo.

---

## Por qué no está activo por defecto

El firmware que usa DietPi (y otras distros headless) al arrancar es `start_cd.elf` — la variante "recortada" diseñada para minimizar el tiempo de boot y el consumo de RAM de GPU. Esta variante **excluye el encoder H.264** del VideoCore.

Adicionalmente, la configuración por defecto asigna solo **16 MB de RAM al GPU**, lo que impide cargar el firmware del codec aunque el archivo de firmware correcto estuviera activo.

| Parámetro | Valor por defecto (headless) | Valor necesario |
|---|---|---|
| Firmware | `start_cd.elf` | `start_x.elf` |
| `start_x` en config.txt | comentado (`#start_x=1`) | activo (`start_x=1`) |
| `gpu_mem` | `16` MB | `128` MB |

---

## Cómo activarlo

### Paso 1 — Modificar `/boot/firmware/config.txt`

```bash
ssh root@<ip-pi> "
  sed -i 's/^#start_x=1/start_x=1/' /boot/firmware/config.txt
  grep -q '^gpu_mem=' /boot/firmware/config.txt \
    && sed -i 's/^gpu_mem=.*/gpu_mem=128/' /boot/firmware/config.txt \
    || echo 'gpu_mem=128' >> /boot/firmware/config.txt
  grep -E 'start_x|gpu_mem' /boot/firmware/config.txt
"
```

La salida esperada:

```
start_x=1
gpu_mem=128
```

`start_x=1` hace que el bootloader cargue `start_x.elf` en lugar de `start_cd.elf`. Este firmware incluye soporte de cámara CSI **y** el encoder H.264 del VideoCore.

### Paso 2 — Reiniciar

```bash
ssh root@<ip-pi> "reboot"
```

El cambio de firmware solo toma efecto en el próximo arranque.

### Paso 3 — Verificar que el módulo y los dispositivos están disponibles

```bash
ssh root@<ip-pi> "lsmod | grep bcm2835 && ls /dev/video{10,11,12,18,31} 2>/dev/null"
```

Salida esperada tras el reboot con `start_x=1` y `gpu_mem=128`:

```
bcm2835_codec         ...
/dev/video10  /dev/video11  /dev/video12  /dev/video18  /dev/video31
```

Si el módulo no carga automáticamente, `ensure-gpu-encoder.sh` escribe
`/etc/modules-load.d/raspi-streaming.conf` y neutraliza el blacklist de
DietPi (`/etc/modprobe.d/dietpi-disable_rpi_codec.conf`). Se ejecuta durante
la instalación y al inicio de cada boot mediante
`boot-stream-orchestrator.service`, por lo que un `apt upgrade` que vuelva a
crear el blacklist se corrige en el siguiente arranque. Ver
[reboot-validation.md](reboot-validation.md) para el diagnóstico completo.

### Paso 4 — Confirmar el encoder en ffmpeg

```bash
ffmpeg -encoders 2>/dev/null | grep v4l2m2m
```

Salida esperada:

```
 V..... h264_v4l2m2m         V4L2 mem2mem H.264 encoder wrapper
```

---

## Cómo funciona en el pipeline

El encoder `h264_v4l2m2m` usa el bloque de hardware H.264 del VideoCore vía el driver del kernel `bcm2835-codec`. El flujo es:

```
Cámara USB (MJPEG) → ffmpeg decodifica a yuvj422p (CPU, liviano)
  → format=yuv420p (conversión 4:2:2→4:2:0, CPU, muy liviano)
  → h264_v4l2m2m (encode H.264 en VideoCore, GPU)
  → RTMP / archivo
```

La conversión de formato es necesaria porque la cámara entrega YUV 4:2:2 y el encoder del VideoCore solo acepta YUV 4:2:0. Este paso es liviano comparado con el encode completo por software.

### Comparación de CPU medida en Pi 3B (1080p 30fps, 2.5Mbps)

| Encoder | FPS obtenidos | CPU user (ffmpeg) | Velocidad |
|---|---|---|---|
| `libx264 ultrafast` | ~27 fps | ~14.7 s | 0.9x |
| `h264_v4l2m2m` | ~29 fps | ~9.6 s | 0.97x |

Reducción de carga de CPU en la etapa de encode: **~35%**.

---

## Overlay + GPU encoder: compatibilidad confirmada

### La duda inicial

Cuando se integró `h264_v4l2m2m` por primera vez, se asumió que era incompatible con overlays. El razonamiento fue: los overlays (logo, texto, timestamp, banner) requieren `filter_complex` de ffmpeg, y ese filtrado corre en CPU produciendo frames de software. Encoders de hardware acelerado (VAAPI, CUDA/NVENC) normalmente exigen que el frame viva en un "hardware frame context" — pasar de CPU a ese contexto requiere `hwupload`, y de vuelta `hwdownload`, con overhead y complejidad extra.

Por esa suposición, se implementó **exclusión mutua** en el portal y en los scripts: activar GPU encoder apagaba overlays automáticamente y viceversa. `stream-overlay.sh` solo intentaba `h264_v4l2m2m` cuando `HAS_OVERLAY=false`.

### La prueba

La suposición nunca se verificó directamente — se decidió probarlo en la Pi real antes de aceptarla como definitiva. Se corrió un ffmpeg de prueba (`-f null -`, sin tocar el stream en vivo) con `drawtext` encadenado directo a `h264_v4l2m2m`, sin ningún `hwupload`:

```bash
ffmpeg -f v4l2 -input_format mjpeg -framerate 30 -video_size 1280x720 -i /dev/video0 \
  -vf 'format=yuv420p,drawtext=text=TEST:...' \
  -vcodec h264_v4l2m2m -b:v 1500000 -f null -
```

Resultado: **corrió sin errores**, a ~29fps y velocidad 0.97x (casi tiempo real). El log confirmó:

```
Stream mapping:
  Stream #0:0 -> #0:0 (rawvideo (native) -> h264 (h264_v4l2m2m))
```

**La suposición era incorrecta.** `h264_v4l2m2m` en ffmpeg es un wrapper V4L2 mem2mem, no un encoder de hardware-frame-context como VAAPI/NVENC — acepta buffers de memoria normal directamente. No necesita `hwupload`/`hwdownload`.

### El incidente durante la prueba

La prueba usó `/dev/video0` (la única cámara USB conectada) en paralelo mientras el stream en vivo (`streaming-overlay.service`) también la tenía abierta. V4L2 no soporta acceso concurrente al dispositivo — esto causó una contención que cortó el stream en vivo por ~2 minutos (`systemctl stop` implícito por el conflicto de dispositivo). Se restauró el servicio inmediatamente después de detectar el corte.

**Lección operativa:** cualquier prueba de ffmpeg contra la cámara en vivo debe hacerse solo con el stream detenido, o aceptando una interrupción breve — no hay forma de probar en paralelo con una sola cámara USB.

### El cambio de código

Se quitó la exclusión mutua y se ajustó el pipeline:

- **`stream-overlay.sh`**: `_HW_ENC` (resultado de `detect_hw_encoder()`) ahora se calcula una sola vez, después de determinar `HAS_OVERLAY`, y se usa en ambas ramas (con y sin overlay). Cuando hay overlays **y** GPU encoder activo, se agrega un filtro final `format=yuv420p` al `filter_complex` — necesario porque las imágenes PNG de overlay (logo) dejan el frame en un formato con canal alpha (`yuva420p`/`rgba`) que `h264_v4l2m2m` no acepta; el encoder solo trabaja en YUV 4:2:0 plano.
- **`app.js`**: se eliminaron los listeners de exclusión mutua entre los toggles de Overlay y GPU Encoder. Ambos son independientes ahora.
- **`index.html`**: el texto del toggle GPU se actualizó para reflejar la compatibilidad.

La variable `GPU_ENCODER` en `/etc/streaming.env` sigue igual:

```
GPU_ENCODER=true   # usa h264_v4l2m2m si el hardware lo soporta (con o sin overlays)
GPU_ENCODER=false  # siempre libx264
```

### Resultado en producción (Pi 3B, prueba en vivo)

Con el stream real transmitiendo a YouTube, se activaron simultáneamente: logo (PNG, esquina superior derecha), texto personalizado, timestamp y banner de texto — los 4 tipos de overlay a la vez, más GPU encoder:

```
ffmpeg ... -filter_complex [1:v]scale=120:-1[logo_s],[0:v][logo_s]overlay=...[vlogo],
  [vlogo]drawtext=...[vtext],[vtext]drawtext=...[vts],[vts]drawbox=...,drawtext=...[vbanner],
  [vbanner]format=yuv420p[vgpu] -map [vgpu] -map 2:a:0 -vcodec h264_v4l2m2m -b:v 2500000 -f flv ...
```

| Parámetro | Valor |
|---|---|
| Resolución | 1280×720 @ 30fps |
| Bitrate | 2.5 Mbps |
| Overlays activos | logo + texto + timestamp + banner (los 4 a la vez) |
| Encoder | `h264_v4l2m2m` (GPU VideoCore) |
| **CPU medido** | **59.1%** |
| Destino | YouTube (RTMP en vivo) |

Como referencia, la documentación de overlays (`docs/overlays.md`) reporta que 2-3 overlays con `libx264 veryfast` en Pi 3B ya se acercan a saturación (80-95% CPU), y 4+ overlays "posible saturación". Con GPU encoder, los mismos 4 overlays simultáneos quedaron en 59% — margen considerable de sobra.

### Qué sigue costando CPU

El GPU encoder solo delega la **etapa de encode H.264**. Estas etapas siguen en CPU sin importar el encoder:

- Decodificación MJPEG de la cámara USB → yuvj422p
- `filter_complex`: overlay de imágenes, `drawtext`, `drawbox`
- Conversión final `format=yuv420p`

Por eso overlays con GPU encoder siguen costando más CPU que GPU encoder sin overlays (~50% medido previamente) — la diferencia (~9 puntos porcentuales en esta prueba) es el costo real del filtrado, no del encode.

---

## Bug encontrado: preview local fallaba con GPU encoder (mediamtx rechaza el stream)

### El síntoma

Con `GPU_ENCODER=true`, el stream en vivo a YouTube funcionaba bien, pero la **vista previa local** (que usa `mediamtx` como servidor RTMP en `localhost:1935`) fallaba sistemáticamente: `preview.service` entraba en loop de reinicio (`activating (auto-restart)`), y el log de mediamtx mostraba:

```
INF [RTMP] [conn [::1]:xxxxx] opened
INF [RTMP] [conn [::1]:xxxxx] closed: unable to parse H264 config: EOF
```

La conexión se cerraba casi de inmediato (~1 segundo), siempre con el mismo error.

### El diagnóstico

`h264_v4l2m2m` en ffmpeg **nunca rellena `AVCodecContext.extradata`** (el SPS/PPS que describe el stream H.264). Cuando el muxer FLV abre la conexión RTMP, necesita ese extradata para construir el "AVC sequence header" — el primer paquete que declara el códec al servidor. Sin extradata, ffmpeg envía un header vacío o inválido.

- **YouTube/Facebook toleran esto**: derivan el SPS/PPS directamente de los NALs que van embebidos en el propio stream (Annex-B), sin depender del header inicial.
- **mediamtx es estricto**: valida el header al conectar y, si está vacío, cierra la conexión inmediatamente con `unable to parse H264 config: EOF`.

Esto explica por qué el stream en vivo a YouTube funcionaba desde el principio (documentado arriba, 59.1% CPU) mientras el preview fallaba — apuntan a servidores RTMP con distinto nivel de tolerancia.

### Los intentos que no funcionaron

Se probaron los bitstream filters diseñados para extraer/inyectar extradata:

```bash
-bsf:v extract_extradata   # extrae SPS/PPS del stream hacia el extradata del contexto
-bsf:v dump_extra=freq=keyframe  # inyecta el extradata conocido antes de cada keyframe
```

Ninguno resolvió el problema en el caso RTMP en vivo. La razón: estos filtros necesitan que **ya exista** un paquete codificado para extraer o inyectar el extradata — pero el muxer FLV escribe su header **antes** de que fluya el primer paquete (más aún con `h264_v4l2m2m`, que tiene "hardware delay" y tarda en emitir el primer frame). Cuando se probó `extract_extradata` contra un **archivo local** (seekable), sí funcionó (`extradata_size=56` confirmado con `ffprobe`) — porque ffmpeg puede reescribir el header al cerrar el archivo. Contra una conexión de red (no seekable), no hay segunda oportunidad.

### La solución: pipeline de dos etapas vía MPEG-TS

MPEG-TS no necesita extradata declarado por adelantado — el SPS/PPS viaja embebido en el propio stream (igual que Annex-B) y el demuxer TS los extrae al leer. La solución es codificar a un TS intermedio y remuxear con `-c copy` (sin recodificar) al FLV/RTMP final en un segundo proceso ffmpeg:

```bash
ffmpeg <captura + filtros> -vcodec h264_v4l2m2m -b:v "$BITRATE" -f mpegts - \
  | ffmpeg -f mpegts -i - -c copy -f flv "$URL"
```

Para cuando el segundo ffmpeg abre la conexión RTMP, ya leyó suficiente del TS entrante para conocer el SPS/PPS — el header que envía a mediamtx (o a cualquier servidor RTMP) ya viene completo.

Verificado en la Pi: mediamtx pasó de rechazar la conexión a reportar:

```
INF [path preview] stream is available and online, 2 tracks (H264, MPEG-4 Audio)
INF [RTMP] [conn [::1]:xxxxx] is publishing to path 'preview'
```

### La implementación

`stream-overlay.sh` ahora tiene una función `run_ffmpeg_pipeline()` que decide automáticamente:

```bash
run_ffmpeg_pipeline() {
    if [[ "$_HW_ENC" == "h264_v4l2m2m" && "$TRANSPORT" == "rtmp" ]]; then
        ffmpeg ... "$@" -f mpegts - | ffmpeg -f mpegts -i - -c copy "${OUTPUT_ARGS[@]}"
    else
        ffmpeg ... "$@" "${OUTPUT_ARGS[@]}"
    fi
}
```

- Solo aplica el pipeline de dos etapas cuando el encoder es GPU **y** el transporte es `rtmp` — el modo `tcp`/`udp` de preview (MPEG-TS directo) ya no necesita el fix, porque el formato de salida ya es TS.
- El stream en vivo a YouTube, que ya funcionaba directo, ahora también pasa por el pipeline (por simplicidad de código, un solo camino para todos los destinos RTMP) — no rompe nada, solo agrega un proceso `-c copy` adicional con costo de CPU despreciable (~26% observado en la prueba, principalmente por el arranque del proceso; en régimen estable es mucho menor porque es solo remux sin recodificar).

---

## Riesgos y consideraciones

### Impacto en RAM del sistema

Asignar 128 MB al GPU reduce la RAM disponible para el sistema operativo. En Pi 3B con 1 GB total:

| gpu_mem | RAM para sistema | Uso típico del sistema |
|---|---|---|
| 16 MB (default) | ~1008 MB | ~472 MB usado |
| 128 MB | ~896 MB | ~472 MB usado |

Margen libre tras el cambio: ~424 MB. No representa un riesgo en uso normal.

### Tiempo de arranque ligeramente mayor

`start_x.elf` es mayor que `start_cd.elf`. El tiempo de boot aumenta algunos segundos. No es relevante para un sistema de streaming que arranca una sola vez.

### Incompatibilidad con `gpu_mem_256`, `gpu_mem_512`, `gpu_mem_1024`

Config.txt puede tener variantes condicionales por tamaño de RAM (`gpu_mem_1024=16`). Estas sobreescriben `gpu_mem` si están presentes. Verificar y ajustar también esas líneas:

```bash
grep 'gpu_mem' /boot/firmware/config.txt
```

Si aparecen líneas como `gpu_mem_1024=16`, cambiarlas a `gpu_mem_1024=128`.

### El encoder no está garantizado en todos los Pi

| Modelo | VideoCore | h264_v4l2m2m | Notas |
|---|---|---|---|
| Pi 3B / 3B+ | VideoCore IV | Sí, con `start_x=1` | Verificado |
| Pi 4B | VideoCore VI | Sí | Requiere kernel 5.x+ |
| Pi Zero 2 W | VideoCore IV | Probable | No verificado |
| Pi 5 | VideoCore VII | No (usa `v4l2_request`) | API diferente |

### Fallback automático

Si `detect_hw_encoder()` no detecta el hardware (módulo no cargado, dispositivos ausentes, firmware incorrecto), todos los scripts caen silenciosamente a `libx264`. No hay error fatal.

### Overlays con imágenes PNG y canal alpha

Los overlays de imagen (logo, marco) pueden dejar el frame en `yuva420p` o `rgba` tras el `overlay` filter de ffmpeg. `h264_v4l2m2m` no acepta esos formatos — solo YUV 4:2:0 plano sin alpha. El pipeline agrega automáticamente un filtro `format=yuv420p` al final de la cadena cuando detecta overlays + GPU encoder combinados; no requiere configuración manual.

---

## Desactivarlo

Para volver al estado original (firmware recortado, mínimo uso de GPU):

```bash
sed -i 's/^start_x=1/#start_x=1/' /boot/firmware/config.txt
sed -i 's/^gpu_mem=128/gpu_mem=16/' /boot/firmware/config.txt
reboot
```

O simplemente desactivar el toggle GPU en el portal — los scripts siempre comprueban el hardware en tiempo de ejecución.
