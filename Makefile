ENV ?= stage
APP_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
COMPOSE = docker compose --env-file env/$(ENV).env -f docker-compose.yml -f compose.$(ENV).yml

.PHONY: up down deploy migrate smoke rollback backup restore lint test build scan ci config-check no-destructive package

config-check:
	cd deploy && test -f runtime.env || touch runtime.env && docker compose --env-file env/$(ENV).env -f docker-compose.yml -f compose.$(ENV).yml config >/dev/null

no-destructive:
	! grep -rnE "compose +down +-v|compose +down +.*--volumes" deploy scripts || (echo "destructive command found!" && exit 1)

migrate:
	cd deploy && APP_VERSION=$(APP_VERSION) docker compose --env-file env/$(ENV).env -f docker-compose.yml -f compose.$(ENV).yml --profile tools run --rm migrator

deploy: no-destructive
	cd deploy && ENV=$(ENV) APP_VERSION=$(APP_VERSION) ./deploy.sh $(ENV)

smoke:
	./scripts/smoke.sh $(ENV)

rollback:
	cd deploy && ./rollback.sh $(VERSION) $(ENV)

backup:
	cd deploy && ./backup.sh

restore:
	cd deploy && ./restore.sh $(FILE) $(ARGS)

lint:
	ruff check services mock-provider
	ruff format --check services mock-provider

test:
	PYTHONPATH=services/api pytest services/api/tests -q
	PYTHONPATH=services/worker pytest services/worker/tests -q

build:
	cd deploy && touch runtime.env && APP_VERSION=$(APP_VERSION) docker compose --env-file env/$(ENV).env -f docker-compose.yml -f compose.$(ENV).yml build api worker mock-provider

scan:
	trivy fs --severity HIGH,CRITICAL --exit-code 1 services/ mock-provider/
	trivy config --severity HIGH,CRITICAL --exit-code 1 deploy/ || true

ci: lint test build
	@echo "local CI OK"

package:
	./scripts/package.sh

up:
	cd deploy && test -f runtime.env || touch runtime.env && docker compose --env-file env/$(ENV).env -f docker-compose.yml -f compose.$(ENV).yml up -d --wait

down:
	cd deploy && test -f runtime.env || touch runtime.env && docker compose --env-file env/$(ENV).env -f docker-compose.yml -f compose.$(ENV).yml down --remove-orphans
