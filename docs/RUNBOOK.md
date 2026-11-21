# RUNBOOK

## Деплой
`export DB_PASSWORD RABBITMQ_PASSWORD PROVIDER_API_KEY [VAULT_DEV_ROOT_TOKEN]; make deploy ENV=stage` → жди `deploy OK`. Токен Vault стабилен на env: заданный переиспользуется, иначе генерируется в gitignored `.vault-token-<env>` (не удаляй — смена токена пересоздает dev-Vault и стирает секреты). Не используй `down -v` — сносит тома. Оверлей подключается автоматически: `docker-compose.yml + compose.<env>.yml`.
Deploy берёт `.deploy-lock-<env>` (`flock`), отказывается собирать dirty tree (`ALLOW_DIRTY=1` — только осознанно) и перед migrator делает pre-migration backup. Мигратор ждёт advisory lock до 30s, падает по таймауту, проверяет checksums и имеет `lock_timeout/statement_timeout`.
Окружения изолированы: project `payment-stack-stage` / `payment-stack-prod`, секреты в `deploy/runtime.<env>.env`, бэкапы в `backups/<env>/`. Для старого стенда с проектом `deploy` используй `PAYMENT_STACK_PROJECT=deploy PAYMENT_STACK_RUNTIME_ENV=runtime.env` (только на время миграции) — это сохраняет старые контейнеры/тома и не конфликтует по порту 8080. Если переходишь на новый project name, сначала останови старый без удаления томов: `PAYMENT_STACK_PROJECT=deploy PAYMENT_STACK_RUNTIME_ENV=runtime.env make down ENV=stage` (это `down --remove-orphans`, без `-v`), затем перенеси тома или прими пустой стенд.
Версия: `APP_VERSION` → git SHA → `VERSION` → `nogit-<UTC>`. Успешный деплой пишет `.deploy-state-<env>` и строку в `.deploy-history-<env>` (timestamp, version, image IDs).
В prod debug-порты (15672/9090) не публикуются; в stage — только на `127.0.0.1`. RabbitMQ Prometheus plugin (`:15692`) доступен только внутри compose-сети.

## CD (GitHub Actions)
Pipeline `.github/workflows/pipeline.yml`: `test → build-scan-push → deploy-stage → deploy-prod`.
Включается repository variables:
- `STAGE_DEPLOY_ENABLED=true`, `STAGE_DEPLOY_PATH=/opt/payment-stack`, опционально `STAGE_PROJECT`/`STAGE_RUNTIME_ENV`;
- `PROD_DEPLOY_ENABLED=true`, `PROD_DEPLOY_PATH=...`, опционально `PROD_PROJECT`/`PROD_RUNTIME_ENV`.
Нужны self-hosted runners с labels `stage`/`prod`, Git/Docker/make и persistent checkout path с runtime/Vault-секретами. Prod использует environment approval. Deploy делает `git fetch && git checkout --force $GITHUB_SHA`, затем `make deploy`, stage дополнительно `alert-selftest` и `smoke-idempotency`. Без runners/vars deploy jobs пропускаются, pipeline остаётся зелёным. Registry images (full/short SHA) — артефакт сборки/rollback, deploy собирает тот же SHA локально.

## Smoke: хост vs сеть
Хост может не доставать до published-портов (VPN/файрвол режет host→bridge). `deploy.sh`, `rollback.sh` и `restore.sh` сами выбирают: есть `curl` **и** `python3` и доступен `localhost:${API_PORT}/health` → `smoke.sh`, иначе → `scripts/smoke-net.sh` (тот же сценарий POST→COMPLETED, но трафик внутри compose-сети через `reverse-proxy`). Вручную: `SMOKE_BASE=http://reverse-proxy ./scripts/smoke.sh` не выйдет (curl с хоста) — используй `smoke-net.sh`. Проверка учениями — только in-network. `status.sh` тоже умеет fallback (host → exec через worker).

## Смена паролей БД/очереди (без потери данных, без `down -v`)
Пароли живут в двух местах: Vault (эфемерный dev) + pgdata/rabbitmq-volume (постоянные). `seed --force` со свежими DB/Rabbit-паролями на СУЩЕСТВУЮЩЕМ pgdata = `password authentication failed`. Основная процедура — `deploy/vault/rotate.sh` (ALTER в живой БД + `rabbitmqctl change_password` + `seed --force` теми же значениями). `seed --force` напрямую допустим только если меняется лишь `PROVIDER_API_KEY` (DB/Rabbit-пароли те же).
```
export DB_PASSWORD=... RABBITMQ_PASSWORD=... PROVIDER_API_KEY=...
./deploy/vault/rotate.sh stage
make deploy ENV=stage
```
`down -v` — только последний шанс с ПОТЕРЕЙ ДАННЫХ, запрещен `make no-destructive` и CI-чеком.

## Откат
`make rollback ENV=stage VERSION=<version>`; версию смотри в `.deploy-history-stage` (timestamp, kind, version, image IDs), а не только в `.deploy-state-stage`: state хранит последнюю успешную версию, истории предыдущих там нет. Успешный ручной откат обновляет `.deploy-state-stage`, поэтому следующий deploy не примет плохую версию за `PREV`. Образ отката должен быть локально (`docker image inspect`); без `.git`/`dev`-тега откат невозможен — используй образцы тегов из history. Схема НЕ откатывается: если миграция уже ушла, старый код должен быть совместим, иначе чини forward-миграцией `005_...`. Автооткат в `deploy.sh` откатывает `api worker outbox mock-provider` на smoke/readiness-фейле; при нездоровых DB/Rabbit код не откатывается. Сломанная миграция и bind-mount конфиги nginx/monitoring автооткатом не чинятся. Если версия старше outbox (pre-`004`/pre-outbox), откат останавливает `outbox` и возвращает старый direct-publish путь. Ручной rollback и deploy/rotate/restore сериализованы `flock`.

## Пропали секреты
`render-env.sh` падает `FATAL: missing secrets` → проверь `docker compose exec -T vault vault kv get secret/payment-stack/stage`.
Если ключ есть, но битый/устаревший, `seed.sh` без флага ничего не сделает (защита от затирания). Если меняются DB/Rabbit-пароли — только `./deploy/vault/rotate.sh stage` (см. выше). Если меняется только provider key:
```
export DB_PASSWORD=... RABBITMQ_PASSWORD=... PROVIDER_API_KEY=...
./deploy/vault/seed.sh stage --force
./deploy/vault/render-env.sh stage --strict
make deploy ENV=stage
```
`--strict` отказывается от плейсхолдеров короче 12 символов / `change-me*` / `test-*`. Файл секретов — `deploy/runtime.stage.env` (0600), prod — `runtime.prod.env`.

## Очередь растет (PENDING стареет)
1. `./scripts/status.sh stage` (метрики тянет in-network, `/metrics` наружу закрыт) или `curl 127.0.0.1:9090/api/v1/query?query=api_pending_transfers` в stage.
2. Глубина очередей: `curl 127.0.0.1:9090/api/v1/query?query=rabbitmq_queue_messages` или `docker compose --env-file env/stage.env -f docker-compose.yml -f compose.stage.yml exec -T rabbitmq rabbitmqctl list_queues name messages consumers`.
3. `docker compose logs worker` (retry/poison/dlq, `request_id=transfer_id`).
4. Проверь `mock-provider failing` (с ключом: `curl -X POST -H 'X-Admin-Key: $PROVIDER_API_KEY' .../admin/fail-mode`) и алерты `PoisonQueueGrowing`, `DlqNonEmpty` (теперь `rabbitmq_queue_messages{queue="transfers.dlq"} > 0`), `TransferQueueBacklog`, `OldestPendingTooOld`, `RabbitMQDown`.

Разбор DLQ:
```
make dlq-replay ENV=stage ARGS="--dry-run"   # сколько сообщений и сколько replayable
make dlq-replay ENV=stage ARGS="--limit 50"  # вернуть валидные в transfers, retry-заголовки сброшены
make dlq-replay ENV=stage ARGS="--all"       # включая poison (обычно снова уйдёт в DLQ)
```
По умолчанию невалидный poison остаётся в DLQ для ручного разбора. Републикация в worker: backoff `min(2^retry,16s)`, `LookupError` (нет transfer) — сразу DLQ.

## Outbox застрял / RabbitMQ недоступен
API принимает перевод в `transfer_outbox` даже при упавшем RabbitMQ: `POST /transfers` → 202, `/health` покажет `broker=down`, `/ready` останется 200 (проверяет только БД). Смотри:
```
docker compose logs outbox
docker compose exec -T db psql -U payments -d payments -c \
  "SELECT status,count(*),min(created_at),max(attempts) FROM transfer_outbox GROUP BY status;"
```
Метрики: `outbox_pending`, `outbox_oldest_seconds`, `outbox_publish_errors_total`; алерты `OutboxDown/OutboxStale/OutboxPendingHigh/OutboxPublishErrors`.
Если outbox лежит — перезапусти `docker compose restart outbox`; если broker недоступен — чини RabbitMQ, outbox сам переподключится и дошлёт. Учение: `make outbox-drill ENV=stage` (останавливает RabbitMQ, проверяет 202 → PENDING → COMPLETED → SENT).
Идемпотентность API: проверка `make smoke-idempotency ENV=stage`; повтор с тем же `Idempotency-Key` и другим телом даёт 409.

## БД недоступна
`api /health` → 503 `{"db":"down"}` (broker при этом остается `up` — чеки независимы, ~2.5s). `up --wait` или smoke упадёт; автооткат кода **не лечит БД** и может быть вреден. `/ready` тоже 503, пока БД недоступна. Чини инфраструктуру, затем повтори деплой:
```
( cd deploy && docker compose --env-file env/<env>.env -f docker-compose.yml -f compose.<env>.yml up -d --wait db )
./deploy/vault/render-env.sh <env> --strict
make migrate ENV=<env> && make deploy ENV=<env>
```
`make migrate` без готового `runtime.<env>.env` упадет — сначала `render-env`.

## Бэкап/восстановление
`make backup ENV=<env>` → `backups/<env>/payments-*.sql.gz + .sha256` (0600), retention `KEEP_DAYS=14`.
Проверка: `make restore FILE=backups/<env>/... ARGS="--verify-only" ENV=<env>` — checksum **обязателен**, дамп восстанавливается во временную БД с `ON_ERROR_STOP`; SQL-ошибка не даёт «verified».
Регрессия: `make restore-selftest ENV=<env>` (валидный/битый/без checksum).
Прод-восстановление: `make restore FILE=... ARGS="--apply" ENV=<env>` — сначала проверка в temp DB, затем safety-backup, остановка api/worker/outbox, DROP+dump в одной транзакции, migrator, api/worker/outbox, smoke. Если apply падает, транзакция откатывается и api/worker/outbox перезапускаются.
Cron: `deploy/backup.cron` (`0 * * * * make backup ENV=stage`) — ставить на хосте; для prod отдельная строка/хост.

## Алерты и health
- Alertmanager доставляет в `alert-sink` (`monitoring/alertmanager.yml`); `Watchdog` всегда горит — проверка `make alert-selftest ENV=<env>`.
- `AlertSinkDown` — sink недоступен; `ApiDown/WorkerDown/RabbitMQDown/OutboxDown 2m`; `DbDown/BrokerDown` по `api_db_up/api_broker_up`; `WorkerNotReady/OutboxNotReady` по `worker_ready/outbox_ready`.
- `OutboxStale/OutboxPendingHigh/OutboxPublishErrors/OrphanPending`, `DlqNonEmpty`, `TransferQueueBacklog`, `OldestPendingTooOld`, `PendingHigh`, `ApiSuccessRateLow`.
- `BackupMissing/BackupStale` по `backup_last_success_timestamp_seconds`/`backup_age_seconds`; `ProviderCertMissing/ProviderCertExpiry` по `/metrics` mock-provider.
- Healthchecks: api `/ready`, worker/outbox `/health`, proxy `/healthz`, Prometheus/Alertmanager `/-/healthy`, alert-sink `/health`; `up --wait` ждёт их.
- Внешний pager/email не настроен: замените URL в `monitoring/alertmanager.yml`; если Prometheus умрёт, внешнего heartbeat нет.

## Учения (защита)
Ломают provider (`fail-mode` — с ключом `X-Admin-Key: $PROVIDER_API_KEY`), убивают db/rabbit, шлют poison JSON, трут секрет. Смотри `./scripts/status.sh [stage|prod]` + Prometheus `/-/healthy` + `/api/v1/alerts` + Alertmanager `/-/healthy` + `make alert-selftest`. После деплоя `make outbox-drill` проверяет outbox при упавшем RabbitMQ.
