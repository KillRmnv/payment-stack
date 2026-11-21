SHELL := /bin/bash
ENV ?= stage
APP_VERSION ?= $(shell ./scripts/version.sh)
COMPOSE = docker compose --env-file env/$(ENV).env -f docker-compose.yml -f compose.$(ENV).yml
RUNTIME_ENV = $(if $(PAYMENT_STACK_RUNTIME_ENV),$(PAYMENT_STACK_RUNTIME_ENV),runtime.$(ENV).env)
# Токен Vault обязателен для compose (fail-fast без дефолта): грузим общим helper.
# ensure_vault_token также выставляет COMPOSE_PROJECT_NAME/STACK_ENV/RUNTIME_ENV_FILE.
ENVLOAD = . ./lib/env.sh && ensure_vault_token $(ENV)

.PHONY: up down deploy deploy-smoke migrate smoke smoke-idempotency outbox-drill alert-selftest rollback backup restore restore-selftest restore-apply-selftest dlq-replay lint test build scan ci config-check no-destructive package

config-check:
	cd deploy && $(ENVLOAD) && { test -f $(RUNTIME_ENV) || touch $(RUNTIME_ENV); } && $(COMPOSE) config >/dev/null

no-destructive:
	! grep -rnE "compose +down +-v|compose +down +.*--volumes" deploy scripts || (echo "destructive command found!" && exit 1)

migrate:
	cd deploy && $(ENVLOAD) && acquire_deploy_lock $(ENV) && APP_VERSION=$(APP_VERSION) $(COMPOSE) --profile tools run --rm migrator

deploy: no-destructive
	cd deploy && ENV=$(ENV) APP_VERSION=$(APP_VERSION) ./deploy.sh $(ENV)

deploy-smoke:
	./scripts/deploy-smoke.sh

smoke:
	./scripts/smoke.sh $(ENV)

smoke-idempotency:
	./scripts/smoke-idempotency.sh $(ENV)

outbox-drill:
	./scripts/outbox-drill.sh $(ENV)

alert-selftest:
	./scripts/alert-selftest.sh $(ENV)

rollback:
	cd deploy && ./rollback.sh $(VERSION) $(ENV)

backup:
	cd deploy && ./backup.sh $(ENV)

restore:
	cd deploy && ./restore.sh $(FILE) $(if $(ARGS),$(ARGS),--verify-only) $(ENV)

restore-selftest:
	./scripts/restore-selftest.sh $(ENV)

restore-apply-selftest:
	./scripts/restore-apply-selftest.sh $(ENV)

dlq-replay:
	./scripts/dlq-replay.sh $(ENV) $(ARGS)

lint:
	ruff check services mock-provider monitoring
	ruff format --check services mock-provider monitoring

test:
	PYTHONPATH=services/api pytest services/api/tests -q
	PYTHONPATH=services/worker pytest services/worker/tests -q

build:
	cd deploy && $(ENVLOAD) && acquire_deploy_lock $(ENV) && { test -f $(RUNTIME_ENV) || touch $(RUNTIME_ENV); } && APP_VERSION=$(APP_VERSION) $(COMPOSE) build api worker mock-provider

scan:
	trivy fs --severity HIGH,CRITICAL --exit-code 1 services/ mock-provider/
	trivy config --severity HIGH,CRITICAL --exit-code 1 deploy/ monitoring/

ci: lint test build
	@echo "local CI OK"

package:
	./scripts/package.sh

up:
	cd deploy && $(ENVLOAD) && acquire_deploy_lock $(ENV) && { test -f $(RUNTIME_ENV) || touch $(RUNTIME_ENV); } && APP_VERSION=$(APP_VERSION) $(COMPOSE) up -d --wait

down:
	cd deploy && $(ENVLOAD) && acquire_deploy_lock $(ENV) && { test -f $(RUNTIME_ENV) || touch $(RUNTIME_ENV); } && $(COMPOSE) down --remove-orphans
