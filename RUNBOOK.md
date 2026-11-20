# RUNBOOK

## Деплой
`export DB_PASSWORD RABBITMQ_PASSWORD PROVIDER_API_KEY VAULT_DEV_ROOT_TOKEN; make deploy ENV=stage` → жди `deploy OK`. Не используй `down -v` — сносит тома.

## Откат
`make rollback ENV=stage VERSION=<prev>` (берется из `.deploy-state-stage`). Схема НЕ откатывается: если миграция уже ушла, чини forward-миграцией `004_...`.

## Пропали секреты
`render-env.sh` падает `FATAL: missing secrets` → `export ...; ./deploy/vault/seed.sh stage; make deploy ENV=stage`. Проверь `vault kv get secret/payment-stack/stage`.

## Очередь растет (PENDING стареет)
1. `curl api:8000/metrics | grep oldest_pending` 2. `rabbitmqctl list_queues` / UI 15672 3. `docker compose logs worker` (retry/poison/dlq) 4. Проверь `mock-provider failing` (`POST /admin/fail-mode`) и алерты `PoisonQueueGrowing/OldestPendingTooOld`.

## БД недоступна
api `/health` → 503 `{"db":"down"}`, smoke падает → автооткат кода (БД та же). Чини `docker compose up -d --wait db`, затем `make migrate ENV=..` и `make deploy`.

## Бэкап/восстановление
`make backup` → `backups/payments-*.sql.gz`; `make restore FILE=...` — восстанавливает во временную БД и считает `transfers` (verify). Прод-режим: cron `0 * * * * make backup`.

## Учения (защита)
Ломают provider (`fail-mode`), убивают db/rabbit, шлют poison JSON, трут секрет — смотри алерты `ApiDown/WorkerDown/DlqNonEmpty/MetricsStale` и `scripts/status.sh`.
