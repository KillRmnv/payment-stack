# RUNBOOK

## Деплой
`export DB_PASSWORD RABBITMQ_PASSWORD PROVIDER_API_KEY VAULT_DEV_ROOT_TOKEN; make deploy ENV=stage` → жди `deploy OK`. Не используй `down -v` — сносит тома. Оверлей подключается автоматически: `docker-compose.yml + compose.<env>.yml` (см. `Makefile COMPOSE`, `deploy.sh COMPOSE`).
В prod debug-порты (15672/9090) не публикуются; в stage — только на `127.0.0.1`.

## Откат
`make rollback ENV=stage VERSION=<prev>` (берется из `.deploy-state-stage`, игнор в `.gitignore`). Схема НЕ откатывается: если миграция уже ушла, старый код должен быть совместим, иначе чини forward-миграцией `004_...`. Автооткат в `deploy.sh` откатывает только `api worker` — сломанная миграция автооткатом не чинится.

## Пропали секреты
`render-env.sh` падает `FATAL: missing secrets` → проверь `docker compose exec -T vault vault kv get secret/payment-stack/stage`.
Если ключ есть, но битый/устаревший, `seed.sh` без флага ничего не сделает (защита от затирания). Ротация:
```
export DB_PASSWORD=... RABBITMQ_PASSWORD=... PROVIDER_API_KEY=...
./deploy/vault/seed.sh stage --force
./deploy/vault/render-env.sh stage --strict
make deploy ENV=stage
```
`--strict` отказывается от плейсхолдеров короче 12 символов / `change-me*` / `test-*`.

## Очередь растет (PENDING стареет)
1. `curl localhost:8080/metrics | grep -E "pending|worker_messages"` 2. `docker compose exec -T rabbitmq rabbitmqctl list_queues` (UI 15672 только в stage на 127.0.0.1) 3. `docker compose logs worker` (retry/poison/dlq, `request_id=transfer_id`) 4. Проверь `mock-provider failing` и алерты `PoisonQueueGrowing(old)/OldestPendingTooOld(>300s 5m)`. Републикация с backoff до 5с, `LookupError` (нет transfer) идет сразу в DLQ как poison, не в retry.

## БД недоступна
`api /health` → 503 `{"db":"down"}`, smoke падает → автооткат кода (БД та же). Чини:
```
docker compose -f docker-compose.yml -f compose.<env>.yml up -d --wait db
./deploy/vault/render-env.sh <env> --strict
make migrate ENV=<env> && make deploy ENV=<env>
```
`make migrate` без готового `runtime.env` упадет — сначала `render-env`.

## Бэкап/восстановление
`make backup` → `backups/payments-*.sql.gz + .sha256`, retention `KEEP_DAYS=14`. `make restore FILE=...` сверяет sha256, восстанавливает во временную БД и считает `transfers/pending + schema_migrations`. Прод-режим: cron `0 * * * * make backup` (cron-файла в репо нет — настраивается на хосте).

## Учения (защита)
Ломают provider (`fail-mode`), убивают db/rabbit, шлют poison JSON, трут секрет. Смотри `./scripts/status.sh [stage|prod]` + Prometheus `/-/healthy` + `/api/v1/alerts` (Alertmanager не подключен — доставка алертов не настроена, см. LIMITS). Алерты: `ApiDown/WorkerDown 2m`, `DlqNonEmpty`, `MetricsStale: absent(up{job="api"}==1) 5m`.
