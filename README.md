# Payment Stack (prod-ready)

## Быстрый старт с нуля (Docker Compose v2 + Git + make + интернет)

```bash
# Секреты в хост-env (в архив/ZIP не класть, в git не коммитить).
# gen: openssl, fallback — python3 или /dev/urandom (openssl может отсутствовать на чистой машине).
gen() { openssl rand -hex 16 2>/dev/null || python3 -c 'import secrets;print(secrets.token_hex(16))' 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n'; }
export DB_PASSWORD=$(gen)
export RABBITMQ_PASSWORD=$(gen)
export PROVIDER_API_KEY=$(gen)
export VAULT_DEV_ROOT_TOKEN=$(gen)

make deploy ENV=stage
# deploy.sh уже делает smoke сам (host или in-network при VPN/без curl).
# Ручная проверка:
# host: curl http://localhost:8080/health (нужен curl, иначе см. ниже)
# изнутри сети без curl на хосте: ./scripts/smoke-net.sh stage
curl http://localhost:8080/health
```

Prod: `make deploy ENV=prod` (порт 8081, проверка `curl http://localhost:8081/health`). Host-smoke требует `curl`+`python3`; без них deploy сам переключается на in-network `smoke-net.sh` (python внутри контейнера, на хосте не нужен).

## Команды

- `make deploy ENV=stage|prod` — идемпотентный деплой (`flock` → dirty-tree check → pre-migration backup → migrate → up → smoke host/in-network, автооткат `api/worker/outbox/mock`). Версия: `APP_VERSION` → git SHA → `VERSION` → `nogit-<UTC>`; история пишется в `.deploy-history-<env>`. Dirty tree блокируется, кроме `ALLOW_DIRTY=1`; мигратор ждёт lock/проверяет checksums.
- `make rollback ENV=stage VERSION=<sha>` — откат кода (схема только вперед, smoke host/in-network). Успешный откат обновляет `.deploy-state-<env>`.
- `make backup ENV=stage|prod` — бэкап `payments` в `backups/<env>/` (sha256 + retention), права `0600`.
- `make restore FILE=... ARGS="--verify-only|--apply" ENV=stage` — checksum обязателен; `--verify-only` восстанавливает в temp DB с `ON_ERROR_STOP`; `--apply` сначала проверяет дамп, делает safety-backup, заливает в одной транзакции, гоняет migrator и smoke.
- `make restore-selftest ENV=stage` — регрессия: валидный дамп проходит, дамп с SQL-ошибкой и дамп без checksum — нет.
- `make dlq-replay ENV=stage ARGS="--dry-run|--limit 50|--all"` — возврат сообщений из `transfers.dlq` в `transfers`; по умолчанию пропускает невалидный poison.
- `make smoke-idempotency ENV=stage` — проверка `Idempotency-Key`: повтор с тем же телом → 200/тот же id, другое тело → 409.
- `make outbox-drill ENV=stage` — учение: остановить RabbitMQ, создать перевод (202 + outbox PENDING), поднять RabbitMQ, дождаться COMPLETED/SENT. Останавливает RabbitMQ на стенде.
- `make alert-selftest ENV=stage` — проверка цепочки Alertmanager → alert-sink по всегда-горящему `Watchdog`.
- `make ci` — локальные lint+test+build; полный pipeline в `.github/workflows/pipeline.yml` (test → build/scan/push → deploy stage → deploy prod с approval)
- `./scripts/smoke.sh [stage|prod]` — host smoke; `./scripts/smoke-net.sh [stage|prod]` — тот же smoke изнутри сети (нужен при VPN на хосте)
- `./scripts/status.sh [stage|prod]` — статусы, health (host + in-network fallback), ключевые метрики
- `./scripts/package.sh [out.zip]` — сборка ZIP для сдачи без секретов: исключаются `runtime*.env`, токены, state/history, `backups`, `.git`; в ZIP кладётся сгенерированный `VERSION`.

Переводы: `POST /transfers` требует `Idempotency-Key` (`REQUIRE_IDEMPOTENCY_KEY=true` по умолчанию; `false` — только legacy). Новый запрос → 202; повтор с тем же ключом и тем же телом → 200 + `X-Idempotent-Replay: true`; тот же ключ с другим телом → 409. API пишет `transfers` + `transfer_outbox` в одной транзакции; сообщение в RabbitMQ отправляет отдельный `outbox`-сервис с publisher confirms, поэтому падение RabbitMQ не теряет принятый перевод.
Секреты: источник — Vault `secret/payment-stack/<env>`. Нет секрета → `render-env.sh --strict` падает с `FATAL`, сервисы не стартуют. Vault-токен обязателен явно (`README` export или `deploy.sh` генерирует в `.vault-token-<env>`); дефолта `dev-only-root-token` больше нет — compose падает с понятным FATAL. Файлы секретов теперь per-env: `deploy/runtime.stage.env` / `deploy/runtime.prod.env` (0600, не коммитить). **Ротация: `./deploy/vault/rotate.sh <env>`**, а не `seed --force`: прямой `seed --force` с новым паролем на существующем `pgdata` ломает аутентификацию.
Компоуз: `docker-compose.yml + compose.<env>.yml`; проекты `payment-stack-stage` и `payment-stack-prod` изолированы (контейнеры, тома, `runtime.<env>.env`, `backups/<env>`). Stage открывает 15672/9090 только на `127.0.0.1`, prod — ничего лишнего. Для старого стенда с проектом `deploy` есть явный escape hatch: `PAYMENT_STACK_PROJECT=deploy PAYMENT_STACK_RUNTIME_ENV=runtime.env make deploy ENV=stage`.
Миграции: `migrator` one-shot до раскатки, advisory lock, откат схемы не поддерживается (автооткат чинит только код).
CI proof: `docs/ci-proof.md` (исторический прогон; текущий pipeline — `.github/workflows/pipeline.yml`). CD включается repository variables `STAGE_DEPLOY_ENABLED`/`PROD_DEPLOY_ENABLED`, путями `STAGE_DEPLOY_PATH`/`PROD_DEPLOY_PATH` и self-hosted runners с labels `stage`/`prod`; stage дополнительно прогоняет `alert-selftest` и `smoke-idempotency`.
Мониторинг: RabbitMQ Prometheus plugin (`rabbitmq:15692`) даёт глубину очередей; `DlqNonEmpty` срабатывает на `transfers.dlq > 0`; `outbox:8002` отдаёт pending/oldest/publish errors; `api_db_up`/`api_broker_up` — доступность БД/брокера. Alertmanager доставляет в локальный `alert-sink`, `Watchdog` — dead man's switch; внешний pager подключается заменой URL. Дашборд: `monitoring/dashboard.json` (uid `payments-10s`, 10 панелей), алерты `monitoring/alerts.yml`.
Подробно: `docs/ARCHITECTURE.md`, `docs/RUNBOOK.md`, `docs/DECISIONS.md`, `docs/ASSUMPTIONS.md`, `docs/LIMITS.md`.
