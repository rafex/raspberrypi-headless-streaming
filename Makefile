# Atajos para instalar y operar web-api (API REST + frontend de control de
# la transmisión) en la Raspberry Pi. Ver docs/web-api.md para el flujo
# completo (age key, .sops.yaml, primer usuario) antes de "make web-api".

.PHONY: help web-api install-web-api enable-web-api disable-web-api \
        start-web-api stop-web-api restart-web-api status-web-api logs-web-api

help:
	@echo "Targets disponibles:"
	@echo "  make web-api          - instala y habilita web-api en boot (requiere sudo)"
	@echo "  make install-web-api  - solo instala (venv, TLS, systemd unit)"
	@echo "  make enable-web-api   - habilita el arranque automático y lo inicia ahora"
	@echo "  make disable-web-api  - deshabilita el arranque automático y lo detiene"
	@echo "  make start-web-api    - inicia el servicio (una vez)"
	@echo "  make stop-web-api     - detiene el servicio"
	@echo "  make restart-web-api  - reinicia el servicio"
	@echo "  make status-web-api   - muestra el estado del servicio"
	@echo "  make logs-web-api     - sigue los logs en tiempo real (journalctl)"
	@echo ""
	@echo "Antes de la primera instalación, ver docs/web-api.md:"
	@echo "  1. generar la age key"
	@echo "  2. configurar .sops.yaml"
	@echo "  3. scripts/manage-users.sh add <usuario> <viewer|operator>"

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
