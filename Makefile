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
        start-web-api stop-web-api restart-web-api status-web-api logs-web-api

WEBAPI_USER ?= admin
WEBAPI_ROLE ?= operator
AGE_KEY_FILE := /etc/raspi-streaming/age/key.txt

help:
	@echo "Setup inicial (en orden, ver docs/web-api.md):"
	@echo "  make deps-web-api    - instala age, sops, uv, openssl (sudo)"
	@echo "  make age-key         - genera la age key y actualiza .sops.yaml"
	@echo "  make add-user        - crea/actualiza un usuario (WEBAPI_USER=admin WEBAPI_ROLE=operator por default)"
	@echo "  make web-api         - instala y habilita el servicio en boot (requiere sudo)"
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

# Setup inicial completo de punta a punta (deps -> age key -> usuario -> servicio).
setup: deps-web-api age-key add-user web-api

deps-web-api:
	sudo ./scripts/install-deps.sh --web-api

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
