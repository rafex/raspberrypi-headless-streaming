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

Si el módulo no carga automáticamente, el script `streaming-install.sh` escribe `/etc/modules-load.d/raspi-streaming.conf` para cargarlo en cada boot.

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

## Cuándo se usa y cuándo no

El encoder GPU solo actúa cuando **no hay overlays activos**.

Los overlays (logo, banner, timestamp, texto) requieren `filter_complex` de ffmpeg, que opera íntegramente en CPU. Encadenar ese pipeline a `h264_v4l2m2m` requeriría `hwupload`/`hwdownload`, lo que añade latencia y complejidad sin beneficio real en Pi 3B. Por eso el sistema implementa exclusión mutua:

- **GPU ON → overlays desactivados automáticamente**
- **Overlays ON → GPU desactivado automáticamente**

Esta lógica existe tanto en el portal web (JavaScript) como en los scripts de streaming (`GPU_ENCODER` solo toma efecto cuando `HAS_OVERLAY=false`).

La variable `GPU_ENCODER` en `/etc/streaming.env` persiste la preferencia:

```
GPU_ENCODER=true   # usa h264_v4l2m2m si el hardware lo soporta
GPU_ENCODER=false  # siempre libx264
```

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

### No afecta overlays existentes

Activar el encoder GPU con el portal en modo "sin overlays" no modifica ninguna configuración de overlay guardada. Al desactivar el GPU encoder y volver a activar overlays, la configuración previa se restaura.

---

## Desactivarlo

Para volver al estado original (firmware recortado, mínimo uso de GPU):

```bash
sed -i 's/^start_x=1/#start_x=1/' /boot/firmware/config.txt
sed -i 's/^gpu_mem=128/gpu_mem=16/' /boot/firmware/config.txt
reboot
```

O simplemente desactivar el toggle GPU en el portal — los scripts siempre comprueban el hardware en tiempo de ejecución.
