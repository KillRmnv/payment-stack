ENV ?= stage
APP_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

.PHONY: up down deploy migrate smoke rollback backup restore lint test build scan ci config-check no-destructive

config-check:
	cd deploy && docker compose --env-file env/$(ENV).env config >/dev/null

no-destructive:
	! grep -rnE "compose +down +-v|compose +down +.*--volumes" deploy/*.sh scripts/*.sh || (echo "destructive command found!" && exit 1)

migrate:
	cd deploy && APP_VERSION=$(APP_VERSION) docker compose --env-file env/$(ENV).env --profile tools run --rm migrator

deploy: no-destructive
	cd deploy && ENV=$(ENV) APP_VERSION=$(APP_VERSION) ./deploy.sh $(ENV)

smoke:
	./scripts/smoke.sh $(ENV)

rollback:
	cd deploy && ./rollback.sh $(VERSION) $(ENV)

backup:
	cd deploy && ./backup.sh

restore:
	cd deploy && ./restore.sh $(FILE)

lint:
	ruff check services mock-provider
	ruff format --check services mock-provider || true

test:
	PYTHONPATH=services/api pytest services/api/tests -q
	PYTHONPATH=services/worker pytest services/worker/tests -q

build:
	cd deploy && touch runtime.env && docker compose build api worker mock-provider

scan:
	trivy fs --severity HIGH,CRITICAL --exit-code 1 services/ || true

ci: lint test build
	@echo "local CI OK"

up:
	cd deploy && docker compose --env-file env/$(ENV).env up -d --wait

down:
	cd deploy && docker compose --env-file env/$(ENV).env down --remove-orphans
