# Setup

Guía de instalación y configuración inicial para Raspberry Pi con DietPi/Debian sin interfaz gráfica.

---

## Requisitos de hardware

| Componente | Requisito mínimo |
|---|---|
| Placa | Raspberry Pi 3B o superior |
| Cámara | Raspberry Pi Camera Module (v1, v2, v3) o cámara USB UVC |
| Almacenamiento | microSD 8 GB o más |
| Red | Ethernet o Wi-Fi |

---

## 1. Activar la cámara en DietPi

Si usas DietPi, la cámara debe habilitarse manualmente antes de poder usarla.

```bash
sudo dietpi-config
```

Navegar a:

```
Advanced Options → Camera → Enable
```

Reiniciar el sistema:

```bash
sudo reboot
```

Verificar que la cámara es detectada:

```bash
libcamera-hello --list-cameras
```

Salida esperada (ejemplo con Camera Module v2):

```
Available cameras
-----------------
0 : imx219 [3280x2464 10-bit RGGB] (/base/soc/i2c0mux/i2c@1/imx219@10)
```

---

## 2. Instalación de dependencias

Actualizar repositorios:

```bash
sudo apt update
```

Instalar libcamera y ffmpeg:

```bash
sudo apt install -y libcamera-apps ffmpeg
```

Verificar versiones instaladas:

```bash
libcamera-vid --version
ffmpeg -version
```

---

## 3. Verificar encoding H264 por hardware

La Pi utiliza el bloque de Video Core IV para encoding H264.  
Para confirmar que se usa hardware y no CPU:

```bash
libcamera-vid -t 5000 \
  --width 1920 --height 1080 \
  --framerate 30 \
  --codec h264 \
  -o /dev/null
```

Durante la captura monitorear CPU en otra terminal:

```bash
top
```

El proceso `libcamera-vid` no debe superar ~20–30% de CPU en modo hardware.  
Si supera 80%, el encoding está cayendo a software (revisar versión de libcamera).

---

## 4. Configuración de red (opcional)

Para acceder a la Pi desde otra máquina:

```bash
# Ver IP asignada
ip addr show

# Habilitar SSH si no está activo
sudo systemctl enable ssh --now
```

---

## 5. Estructura del repositorio

Clonar en la Pi:

```bash
git clone https://github.com/rafex/raspberrypi-headless-streaming.git
cd raspberrypi-headless-streaming
```

Dar permisos de ejecución a todos los scripts:

```bash
chmod +x scripts/*.sh
```

---

## 6. Limitaciones conocidas en Raspberry Pi 3B

| Parámetro | Valor recomendado | Motivo |
|---|---|---|
| Resolución | 1080p (1920x1080) | límite estable del encoder |
| FPS | 25–30 | más genera dropped frames |
| Bitrate | 4–5 Mbps | balance calidad / CPU |
| Filtros ffmpeg | máximo 1–2 | cada filtro requiere re-encoding |
| CPU libre en reposo | ~40–60% | necesario para el SO y otros procesos |

**Nota:** 1080p60 no es estable en Pi 3B. Para 60 FPS usar resolución menor (720p).

---

## 7. Automatización con systemd

Para que el stream arranque automáticamente al encender la Pi:

### Instalar el servicio

```bash
sudo scripts/control.sh install
```

Esto copia el archivo de servicio a `/etc/systemd/system/` y crea `/etc/streaming.env`.

### Configurar el stream key

```bash
sudo nano /etc/streaming.env
```

Editar la variable `RTMP_URL` con la URL y key de la plataforma:

```
RTMP_URL=rtmp://a.rtmp.youtube.com/live2/TU_STREAM_KEY
```

### Comandos de control

```bash
# Iniciar el stream
scripts/control.sh start

# Ver estado y logs recientes
scripts/control.sh status

# Ver logs en tiempo real
scripts/control.sh logs

# Habilitar inicio automático en boot
scripts/control.sh enable

# Detener
scripts/control.sh stop

# Reiniciar
scripts/control.sh restart
```

### Ver logs con journald directamente

```bash
# Últimas 50 líneas
journalctl -u streaming.service -n 50

# Tiempo real
journalctl -u streaming.service -f

# Desde el último boot
journalctl -u streaming.service -b
```

---

## Próximo paso

Con la cámara configurada y las dependencias instaladas, continuar con la captura de video:

```bash
scripts/capture.sh
```

Ver [scripts/capture.sh](../scripts/capture.sh) para opciones disponibles.
