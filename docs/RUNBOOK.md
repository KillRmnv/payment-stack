# RUNBOOK

## Деплой
`export DB_PASSWORD RABBITMQ_PASSWORD PROVIDER_API_KEY [VAULT_DEV_ROOT_TOKEN]; make deploy ENV=stage` → жди `deploy OK`. Токен Vault стабилен на env: заданный переиспользуется, иначе генерируется в gitignored `.vault-token-<env>` (не удаляй — смена токена пересоздает dev-Vault и стирает секреты). Не используй `down -v` — сносит тома. Оверлей подключается автоматически: `docker-compose.yml + compose.<env>.yml` (см. `Makefile COMPOSE`, `deploy.sh COMPOSE`).
В prod debug-порты (15672/9090) не публикуются; в stage — только на `127.0.0.1`.

## Smoke: хост vs сеть
Хост может не доставать до published-портов (VPN/файрвол режет host→bridge). `deploy.sh` и `rollback.sh` сами выбирают: доступен `localhost:${API_PORT}/health` → `smoke.sh`, иначе → `scripts/smoke-net.sh` (тот же сценарий POST→COMPLETED, но трафик внутри compose-сети через `reverse-proxy`). Вручную: `SMOKE_BASE=http://reverse-proxy ./scripts/smoke.sh` не выйдет (curl с хоста) — используй `smoke-net.sh`. Проверка учениями — только in-network. `status.sh` тоже умеет fallback (host → exec через worker).

## Смена паролей БД/очереди (без потери данных, без `down -v`)
Пароли живут в двух местах: Vault (эфемерный dev) + pgdata/rabbitmq-volume (постоянные). `seed --force` со свежими паролями на СУЩЕСТВУЮЩЕМ pgdata = `FATAL password authentication failed` (deploy падает на `db-auth-check` с понятной подсказкой, а не на smoke). Основная процедура — `deploy/vault/rotate.sh` (ALTER в живой БД + `rabbitmqctl change_password` + `seed --force` теми же значениями):
```
export DB_PASSWORD=... RABBITMQ_PASSWORD=... PROVIDER_API_KEY=...
./deploy/vault/rotate.sh stage
make deploy ENV=stage
```
`down -v` — только последний шанс с ПОТЕРЕЙ ДАННЫХ, запрещен `make no-destructive` и CI-чеком.

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
1. `curl localhost:8080/metrics | grep -E "pending|worker_messages"` 2. `docker compose exec -T rabbitmq rabbitmqctl list_queues` (UI 15672 только в stage на 127.0.0.1) 3. `docker compose logs worker` (retry/poison/dlq, `request_id=transfer_id`) 4. Проверь `mock-provider failing` (с ключом: `curl -X POST -H 'X-Admin-Key: $PROVIDER_API_KEY' .../admin/fail-mode`) и алерты `PoisonQueueGrowing(old)/DlqNonEmpty(poison|dlq)/OldestPendingTooOld(>300s 5m)/MetricsStaleBusiness`. Републикация с экспоненциальным backoff `min(2^retry,16s)` (окно ~31с на 5 ретраев), `LookupError` (нет transfer) идет сразу в DLQ как poison, не в retry.

## БД недоступна
`api /health` → 503 `{"db":"down"}`, smoke падает → автооткат кода (БД та же). Чини:
```
docker compose -f docker-compose.yml -f compose.<env>.yml up -d --wait db
./deploy/vault/render-env.sh <env> --strict
make migrate ENV=<env> && make deploy ENV=<env>
```
`make migrate` без готового `runtime.env` упадет — сначала `render-env`.

## Бэкап/восстановление
`make backup` → `backups/payments-*.sql.gz + .sha256`, retention `KEEP_DAYS=14`. Проверка: `make restore FILE=... ARGS="--verify-only"` сверяет sha256, восстанавливает во временную БД и считает `transfers/pending + schema_migrations`. Прод-восстановление: `make restore FILE=... ARGS="--apply stage|prod"` — стопает api/worker, заливает дамп в live `payments`, гоняет migrator, поднимает api/worker + smoke. Прод-режим: `deploy/backup.cron` (`0 * * * * make backup`) — ставить на хосте через `crontab -e`.

## Учения (защита)
Ломают provider (`fail-mode` — с ключом `X-Admin-Key: $PROVIDER_API_KEY`), убивают db/rabbit, шлют poison JSON, трут секрет. Смотри `./scripts/status.sh [stage|prod]` + Prometheus `/-/healthy` + `/api/v1/alerts` + Alertmanager `/-/healthy` (receiver по умолчанию blackhole — доставку настраивать в `monitoring/alertmanager.yml`). Алерты: `ApiDown/WorkerDown 2m`, `DlqNonEmpty(poison|dlq)/PoisonQueueGrowing 2m`, `MetricsStaleApi/MetricsStaleWorker/MetricsStaleBusiness: absent 5m`.
