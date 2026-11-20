SHELL := /bin/bash
ENV ?= stage
APP_VERSION ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
COMPOSE = docker compose --env-file env/$(ENV).env -f docker-compose.yml -f compose.$(ENV).yml
# Токен Vault обязателен для compose (fail-fast без дефолта): грузим общим helper.
ENVLOAD = . ./lib/env.sh && ensure_vault_token $(ENV)

.PHONY: up down deploy migrate smoke rollback backup restore lint test build scan ci config-check no-destructive package

config-check:
	cd deploy && $(ENVLOAD) && { test -f runtime.env || touch runtime.env; } && $(COMPOSE) config >/dev/null

no-destructive:
	! grep -rnE "compose +down +-v|compose +down +.*--volumes" deploy scripts || (echo "destructive command found!" && exit 1)

migrate:
	cd deploy && $(ENVLOAD) && APP_VERSION=$(APP_VERSION) $(COMPOSE) --profile tools run --rm migrator

deploy: no-destructive
	cd deploy && ENV=$(ENV) APP_VERSION=$(APP_VERSION) ./deploy.sh $(ENV)

smoke:
	./scripts/smoke.sh $(ENV)

rollback:
	cd deploy && ./rollback.sh $(VERSION) $(ENV)

backup:
	cd deploy && ./backup.sh $(ENV)

restore:
	cd deploy && ./restore.sh $(FILE) $(ARGS) $(ENV)

lint:
	ruff check services mock-provider
	ruff format --check services mock-provider

test:
	PYTHONPATH=services/api pytest services/api/tests -q
	PYTHONPATH=services/worker pytest services/worker/tests -q

build:
	cd deploy && $(ENVLOAD) && { test -f runtime.env || touch runtime.env; } && APP_VERSION=$(APP_VERSION) $(COMPOSE) build api worker mock-provider

scan:
	trivy fs --severity HIGH,CRITICAL --exit-code 1 services/ mock-provider/
	trivy config --severity HIGH,CRITICAL --exit-code 1 deploy/ monitoring/

ci: lint test build
	@echo "local CI OK"

package:
	./scripts/package.sh

up:
	cd deploy && $(ENVLOAD) && { test -f runtime.env || touch runtime.env; } && $(COMPOSE) up -d --wait

down:
	cd deploy && $(ENVLOAD) && { test -f runtime.env || touch runtime.env; } && $(COMPOSE) down --remove-orphans
