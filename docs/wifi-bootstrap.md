# WiFi bootstrap y modo hotspot

`raspi-wifi-bootstrap.service` corre al arrancar antes del portal web y de los
servicios de streaming. Su responsabilidad es dejar a la Raspi conectada a una
red conocida o, si no puede, levantar un hotspot de configuración.

No inicia `streaming.service`, `streaming-overlay.service` ni `preview.service`.
Esos servicios deben arrancarse solo desde el portal web, el TUI o comandos
explícitos.

## Configuración

Archivo:

```bash
/etc/raspi-streaming/wifi-networks.toml
```

Ejemplo:

```toml
[hotspot]
interface = "wlan0"
ssid = "RaspiStreaming-Setup"
password = "raspistream"
country = "MX"
channel = 6
address = "10.41.0.1/24"
dhcp_start = "10.41.0.20"
dhcp_end = "10.41.0.80"
portal_port = 8088

[[networks]]
ssid = "Casa"
password = "clave"
priority = 10
hidden = false

[[networks]]
ssid = "Backup"
password = "clave"
priority = 20
hidden = false
```

Las redes se prueban por `priority` ascendente. Si todas fallan, la Raspi crea
el AP definido en `[hotspot]`.

## Portal de emergencia

Conectarse al SSID configurado, por defecto:

```text
RaspiStreaming-Setup
```

Abrir:

```text
http://10.41.0.1:8088
```

Desde ahí se puede agregar una nueva red WiFi y reintentar conexión.

## Instalación

```bash
make wifi-bootstrap
sudo systemctl start raspi-wifi-bootstrap.service
```

Ver estado/logs:

```bash
make status-wifi-bootstrap
make logs-wifi-bootstrap
```
