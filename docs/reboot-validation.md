# Validación de arranque limpio (reboot end-to-end)

Registro de la prueba de reinicio completo del sistema y el bug que reveló: el
GPU encoder nunca se activaba en un arranque real, aunque todas las pruebas
manuales previas (misma sesión) lo mostraban funcionando.

---

## Por qué las pruebas anteriores "funcionaban" pero eran engañosas

Todas las verificaciones de `h264_v4l2m2m` documentadas en `docs/gpu-encoder.md`
se hicieron **sin reiniciar la Pi** después de la instalación inicial. En algún
punto de esa sesión se ejecutó `modprobe bcm2835-codec` manualmente como root
(vía SSH) para diagnosticar el hardware. Un módulo de kernel, una vez cargado,
permanece residente en memoria hasta el próximo reboot — así que **todas** las
pruebas posteriores (stream en vivo, preview, overlays combinados) se
beneficiaron de ese módulo ya cargado, sin que ningún mecanismo automático
lo hubiera cargado por sí mismo.

Esto quedó expuesto recién al hacer un reinicio real de punta a punta.

---

## El bug: DietPi bloquea bcm2835_codec por defecto

Al reiniciar, `lsmod | grep bcm2835` no mostraba nada — el módulo no se había
cargado. `streaming-install.sh` ya escribía `/etc/modules-load.d/raspi-streaming.conf`
con la línea `bcm2835-codec` para carga automática, pero el journal reveló:

```
systemd-modules-load[126]: Module 'bcm2835_codec' is deny-listed (by kmod)
```

DietPi trae de fábrica `/etc/modprobe.d/dietpi-disable_rpi_codec.conf` con:

```
blacklist bcm2835_codec
```

`systemd-modules-load` respeta las directivas `blacklist` de `modprobe.d` y
descarta silenciosamente cualquier entrada de `modules-load.d` que las
contradiga — sin error visible salvo esa línea en el journal, fácil de pasar
por alto.

### Por qué el auto-recuperado de `detect_hw_encoder()` tampoco alcanzaba

`common.sh` ya tenía un intento de `modprobe bcm2835-codec` como fallback
dentro de `detect_hw_encoder()`, pensado para el caso en que el módulo no
esté cargado. Pero `streaming-overlay.service` corre como el usuario de
sistema `streamer` (sin privilegios, sin shell, sin sudo) — y **cargar un
módulo de kernel requiere root**. El `modprobe` fallaba silenciosamente
(`|| true` lo ocultaba) y el script caía a `libx264` sin ningún mensaje de
error explícito, solo el aviso genérico de "overlays requieren CPU".

---

## El fix (dos capas)

### 1. Neutralizar el blacklist en la instalación (`streaming-install.sh`)

```bash
DIETPI_BLACKLIST="/etc/modprobe.d/dietpi-disable_rpi_codec.conf"
if [[ -f "$DIETPI_BLACKLIST" ]] && grep -q '^blacklist bcm2835_codec' "$DIETPI_BLACKLIST"; then
    sed -i 's/^blacklist bcm2835_codec/#blacklist bcm2835_codec  # comentado por raspi-streaming (GPU encoder)/' "$DIETPI_BLACKLIST"
fi
```

Esto hace que `systemd-modules-load` cargue el módulo automáticamente en
**cada** arranque, sin depender de que algo más lo pida.

### 2. Defensa adicional en el arranque automático (`boot-stream-orchestrator.sh`)

Por si el fix de instalación no se ha vuelto a aplicar en un host ya
desplegado, el orquestador (que sí corre como root) hace su propio
`modprobe` justo antes de arrancar el stream automático:

```bash
if grep -q '^GPU_ENCODER=true' "$STREAMING_ENV" 2>/dev/null; then
    if ! lsmod 2>/dev/null | grep -q bcm2835_codec; then
        modprobe bcm2835-codec 2>/dev/null || true
    fi
fi
```

Esto no reemplaza el fix #1 (que es el que garantiza carga automática para
el caso de "Iniciar" manual desde el portal, no solo el auto-stream), pero
añade robustez para el camino de auto-stream específicamente.

---

## Verificación: dos reinicios reales

### Reinicio 1 (antes del fix)

- `bcm2835_codec` no cargó — `lsmod` vacío, `/dev/video10-31` ausentes
- `boot-stream-orchestrator` arrancó `streaming-overlay.service` igual (por diseño, con fallback a libx264)
- Primer intento de ffmpeg falló con `Device or resource busy` en `/dev/video0` — probablemente el driver UVC aún estabilizándose
- `systemd` reintentó automáticamente (`RestartSec=10`) y el segundo intento sí levantó, pero **usando libx264**, no GPU

### Reinicio 2 (después del fix)

- `bcm2835_codec` cargó automáticamente, sin intervención manual — confirmado con `lsmod` inmediatamente tras el boot
- `/dev/video10`, `11`, `12`, `18`, `31` presentes desde el arranque
- `boot-stream-orchestrator` arrancó el stream **al primer intento**, sin reinicios de systemd
- Log confirmó: `Encoder: h264_v4l2m2m (GPU VideoCore — con overlays)`

---

## Cambio adicional: más tiempo de estabilización

El "Device or resource busy" del primer reinicio, aunque ya no es el
problema principal, motivó subir `AUTO_STREAM_DELAY_SECONDS` de 120s a
420s (7 minutos) — ver la sección correspondiente en
[boot-flow.md](boot-flow.md#por-qué-420s-7-min-y-no-menos).

---

## Lección para futuras pruebas

**Verificar cualquier cambio de hardware/kernel (módulos, firmware, udev)
con un reinicio real**, no solo con comandos manuales en la sesión SSH
activa. El estado de un módulo cargado a mano se pierde con el siguiente
reboot, y puede ocultar bugs de arranque durante días de pruebas manuales.
