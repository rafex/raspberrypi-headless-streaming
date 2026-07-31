# MTU de red — ajuste a 1492

Por qué se bajó el MTU de `wlan0` de 1500 a 1492 y cómo reproducirlo.

---

## El síntoma

Durante el streaming RTMP con bitrates altos (≥1.5 Mbps), los paquetes grandes sufren fragmentación silenciosa en la red. Esto se manifiesta como:

- Micro-cortes intermitentes en el stream
- Latencia alta o errores de escritura reportados por ffmpeg (`Error writing trailer`, `Immediate exit requested`)
- El stream se ve estable en la Pi pero el receptor (YouTube, Facebook) reporta inestabilidad

---

## El diagnóstico

El MTU físico de `wlan0` estaba en 1500 (el default del kernel). Pero la red real tiene un MTU efectivo de **1492 bytes** — típico de conexiones que usan **PPPoE** (Point-to-Point Protocol over Ethernet), donde el encapsulado PPPoE consume 8 bytes del payload disponible.

Esto se descubrió con un ping con el flag "Don't Fragment" (`-M do`):

```bash
# Con MTU 1500 — falla: el paquete no cabe sin fragmentar
ping -c 1 -M do -s 1472 8.8.8.8
# sendmsg: Mensaje demasiado largo

# Búsqueda binaria del MTU real
for s in 1464 1452 1440 1420 1400; do
  ping -c 1 -M do -s $s -W 2 8.8.8.8 >/dev/null 2>&1 \
    && echo "MTU OK: $((s+28))" && break \
    || echo "MTU fail: $((s+28))"
done
# MTU OK: 1492
```

El `-s` es el tamaño del payload ICMP. Los 28 bytes adicionales son la cabecera IP (20) + ICMP (8). Con `-s 1464`, el paquete total es 1492 bytes — el máximo que pasa sin fragmentarse.

---

## Por qué afecta al streaming RTMP

RTMP sobre TCP usa segmentos de red. Si el MTU del host (1500) es mayor que el MTU real de la red (1492), cada paquete grande que genera ffmpeg:

1. Llega al router con 1500 bytes
2. El router necesita fragmentarlo en 2 partes para enviarlo por PPPoE
3. El receptor reconstruye los fragmentos — pero si un fragmento se pierde, **el paquete completo se descarta**
4. TCP retransmite, aumentando la latencia
5. ffmpeg detecta que el buffer RTMP no avanza y puede cortar la conexión

En streaming de video esto produce artefactos, cortes o desconexiones.

---

## La corrección

### Aplicar inmediatamente (sin reiniciar)

```bash
ip link set wlan0 mtu 1492
```

### Hacer persistente (sobrevive reboot)

En `/etc/network/interfaces`, dentro del bloque `iface wlan0`:

```
iface wlan0 inet dhcp
  ...
  post-up ip link set wlan0 mtu 1492
```

El `post-up` se ejecuta cada vez que la interfaz sube, incluido el arranque.

### Verificar que funciona

```bash
# 1464 payload + 28 cabeceras IP/ICMP = 1492 total — debe pasar sin errores
ping -c 3 -M do -s 1464 8.8.8.8
```

Salida esperada: `0% packet loss`.

---

## Cómo detectarlo en un equipo nuevo

Antes de hacer streaming desde cualquier Pi, verificar el MTU real:

```bash
# Prueba rápida: ¿pasa un paquete de 1500 bytes sin fragmentar?
ping -c 1 -M do -s 1472 8.8.8.8 && echo "MTU 1500 OK" || echo "MTU reducido — investigar"
```

Si falla, buscar el MTU real con la búsqueda binaria del bloque de diagnóstico y ajustar en consecuencia.

---

## Valores de MTU comunes por tipo de red

| Tipo de conexión | MTU típico | Overhead |
|---|---|---|
| Ethernet / WiFi directo | 1500 | — |
| PPPoE (ADSL, fibra con PPPoE) | 1492 | 8 bytes PPPoE |
| VPN WireGuard | 1420 | ~80 bytes |
| VPN OpenVPN (UDP) | 1500 | varía |
| Tunnels (GRE, IPIP) | 1476 | 24 bytes |

En caso de duda, hacer siempre la prueba con `ping -M do` antes de asumir 1500.
