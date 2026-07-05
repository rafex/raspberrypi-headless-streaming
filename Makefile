# Atajos para instalar y operar web-api (API REST + frontend de control de
# la transmisión) en la Raspberry Pi. Ver docs/web-api.md para el detalle.
#
# Setup inicial, en orden:
#   make deps-web-api
#   make age-key
#   make add-user WEBAPI_USER=admin WEBAPI_ROLE=operator
#   make web-api
# (o "make setup" para correr los cuatro en secuencia)

.PHONY: help setup deps-web-api age-key add-user \
        web-api install-web-api enable-web-api disable-web-api \
        wifi-bootstrap install-wifi-bootstrap repair-wifi-bootstrap enforce-wifi-bootstrap start-wifi-bootstrap stop-wifi-bootstrap status-wifi-bootstrap logs-wifi-bootstrap \
        start-web-api stop-web-api restart-web-api status-web-api logs-web-api \
        deploy-web-api update-services \
        streaming start-streaming stop-streaming status-streaming logs-streaming monitor-streaming status-streaming-live \
        start-preview stop-preview status-preview logs-preview

WEBAPI_USER  ?= admin
WEBAPI_ROLE  ?= operator
AGE_KEY_FILE := /etc/raspi-streaming/age/key.txt
INSTALL_DIR  := /opt/web-api
VENV_DIR     := $(INSTALL_DIR)/venv
SYSTEMD_DIR  := /etc/systemd/system
STREAM_USER  := streamer
REPO_DIR     := $(shell pwd)
MONITOR_INTERVAL ?= 2
MONITOR_LOGS ?= 28

help:
	@echo "Setup inicial (en orden, ver docs/web-api.md):"
	@echo "  make deps-web-api    - instala age, sops, uv, openssl (sudo)"
	@echo "  make age-key         - genera la age key y actualiza .sops.yaml"
	@echo "  make add-user        - crea/actualiza un usuario (WEBAPI_USER=admin WEBAPI_ROLE=operator por default)"
	@echo "  make web-api         - instala y habilita el servicio en boot (requiere sudo)"
	@echo "  make wifi-bootstrap  - instala bootstrap WiFi/AP de arranque (requiere sudo)"
	@echo "  make repair-wifi-bootstrap - desactiva DietPi WiFi y deja solo nuestro bootstrap"
	@echo "  make setup           - corre los cuatro anteriores en secuencia"
	@echo ""
	@echo "Atajos día a día:"
	@echo "  make install-web-api - solo instala (venv, TLS, systemd unit)"
	@echo "  make enable-web-api  - habilita el arranque automático y lo inicia ahora"
	@echo "  make disable-web-api - deshabilita el arranque automático y lo detiene"
	@echo "  make start-web-api   - inicia el servicio (una vez)"
	@echo "  make stop-web-api    - detiene el servicio"
	@echo "  make restart-web-api - reinicia el servicio"
	@echo "  make status-web-api  - muestra el estado del servicio"
	@echo "  make logs-web-api    - sigue los logs en tiempo real (journalctl)"
	@echo "  make status-wifi-bootstrap - estado del bootstrap WiFi/AP"
	@echo ""
	@echo "Streaming:"
	@echo "  make streaming         - crea usuario 'streamer' e instala servicios systemd"
	@echo "  make start-streaming   - inicia el stream (sin overlay)"
	@echo "  make stop-streaming    - detiene el stream"
	@echo "  make status-streaming  - muestra el estado del stream"
	@echo "  make logs-streaming    - sigue los logs en tiempo real"
	@echo "  make monitor-streaming - panel vivo: servicios, ffmpeg, red y logs"
	@echo ""
	@echo "Vista previa local (RTMP/MPEG-TS, nunca a la plataforma real):"
	@echo "  make start-preview     - inicia el preview"
	@echo "  make stop-preview      - detiene el preview"
	@echo "  make status-preview    - muestra el estado del preview"
	@echo "  make logs-preview      - sigue los logs en tiempo real"
	@echo ""
	@echo "Actualización rápida (sin reinstalar):"
	@echo "  make deploy-web-api  - copia código Python+estáticos al destino y reinicia"
	@echo "  make update-services - actualiza unit files systemd y recarga daemon"

# Setup inicial completo de punta a punta (deps -> age key -> usuario -> servicio).
setup: deps-web-api age-key add-user web-api

deps-web-api:
	sudo ./scripts/install-deps.sh --web-api

wifi-bootstrap: install-wifi-bootstrap

install-wifi-bootstrap:
	sudo ./scripts/wifi-bootstrap-install.sh

repair-wifi-bootstrap: enforce-wifi-bootstrap

enforce-wifi-bootstrap:
	sudo systemctl disable --now dietpi-wifi-monitor.service 2>/dev/null || true
	sudo systemctl disable --now hostapd.service dnsmasq.service 2>/dev/null || true
	sudo systemctl stop ifup@wlan0.service wpa_supplicant.service NetworkManager.service 2>/dev/null || true
	sudo sh -c 'ps -eo pid,args | awk '"'"'/[w]pa_supplicant/ && /-i ?wlan0/ && /\/etc\/wpa_supplicant/ {print $$1}'"'"' | xargs -r kill' || true
	sudo sh -c 'ps -eo pid,args | awk '"'"'/[d]hclient/ && /wlan0/ {print $$1}'"'"' | xargs -r kill' || true
	sudo systemctl enable raspi-wifi-bootstrap.service
	sudo systemctl restart raspi-wifi-bootstrap.service
	@echo "WiFi bootstrap reparado. Ver logs con: make logs-wifi-bootstrap"

start-wifi-bootstrap:
	sudo systemctl start raspi-wifi-bootstrap.service

stop-wifi-bootstrap:
	sudo systemctl stop raspi-wifi-bootstrap.service

status-wifi-bootstrap:
	systemctl status raspi-wifi-bootstrap.service --no-pager -l

logs-wifi-bootstrap:
	journalctl -u raspi-wifi-bootstrap.service -f

age-key:
	./scripts/web-api-setup-age.sh

add-user:
	SOPS_AGE_KEY_FILE=$(AGE_KEY_FILE) ./scripts/manage-users.sh add $(WEBAPI_USER) $(WEBAPI_ROLE)

# Instala y deja el servicio arrancando automáticamente en cada boot.
web-api: install-web-api enable-web-api

install-web-api:
	sudo ./scripts/web-api-install.sh

enable-web-api:
	sudo systemctl enable --now web-api.service

disable-web-api:
	sudo systemctl disable --now web-api.service

start-web-api:
	sudo systemctl start web-api.service

stop-web-api:
	sudo systemctl stop web-api.service

restart-web-api:
	sudo systemctl restart web-api.service

status-web-api:
	systemctl status web-api.service --no-pager -l

logs-web-api:
	journalctl -u web-api.service -f

# Crea usuario "streamer" e instala los unit files de systemd para streaming.
streaming:
	sudo ./scripts/streaming-install.sh

start-streaming:
	sudo systemctl start streaming.service

stop-streaming:
	sudo systemctl stop streaming.service

status-streaming:
	systemctl status streaming.service --no-pager -l

logs-streaming:
	journalctl -u streaming.service -f

monitor-streaming:
	./scripts/stream-status-live.sh --interval $(MONITOR_INTERVAL) --logs $(MONITOR_LOGS)

status-streaming-live:
	./scripts/stream-status-live.sh --once --logs $(MONITOR_LOGS)

start-preview:
	sudo systemctl start preview.service

stop-preview:
	sudo systemctl stop preview.service

status-preview:
	systemctl status preview.service --no-pager -l

logs-preview:
	journalctl -u preview.service -f

# Copia código Python y estáticos al directorio de instalación y reinicia el servicio.
# Usar después de hacer "git pull" cuando solo cambian archivos de server/webapi/.
deploy-web-api:
	sudo cp -r server/webapi/. $(INSTALL_DIR)/webapi/
	sudo chown -R webapi:webapi $(INSTALL_DIR)/webapi
	sudo uv pip install --quiet --python $(VENV_DIR)/bin/python \
	    -r server/webapi/requirements.txt
	sudo systemctl restart web-api.service
	@echo "Desplegado: $(INSTALL_DIR)/webapi  →  dependencias actualizadas  →  web-api reiniciado"

# Actualiza los unit files de systemd desde el repositorio y recarga el daemon.
# Usar después de hacer "git pull" cuando cambian archivos de systemd/.
update-services:
	sed "s|__REPO_DIR__|$(REPO_DIR)|g" systemd/raspi-wifi-bootstrap.service \
	    | sudo tee $(SYSTEMD_DIR)/raspi-wifi-bootstrap.service > /dev/null
	sed "s|__VENV_DIR__|$(VENV_DIR)|g" systemd/web-api.service \
	    | sudo tee $(SYSTEMD_DIR)/web-api.service > /dev/null
	sed -e "s|__STREAM_USER__|$(STREAM_USER)|g" \
	    -e "s|__REPO_DIR__|$(REPO_DIR)|g" \
	    systemd/streaming.service \
	    | sudo tee $(SYSTEMD_DIR)/streaming.service > /dev/null
	sed -e "s|__STREAM_USER__|$(STREAM_USER)|g" \
	    -e "s|__REPO_DIR__|$(REPO_DIR)|g" \
	    systemd/streaming-overlay.service \
	    | sudo tee $(SYSTEMD_DIR)/streaming-overlay.service > /dev/null
	sed -e "s|__STREAM_USER__|$(STREAM_USER)|g" \
	    -e "s|__REPO_DIR__|$(REPO_DIR)|g" \
	    systemd/preview.service \
	    | sudo tee $(SYSTEMD_DIR)/preview.service > /dev/null
	sudo systemctl daemon-reload
	sudo systemctl restart web-api.service
	sudo systemctl disable streaming.service streaming-overlay.service preview.service || true
	@echo "Servicios actualizados: user=$(STREAM_USER), repo=$(REPO_DIR)"
