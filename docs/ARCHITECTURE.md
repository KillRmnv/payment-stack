# ARCHITECTURE

```
client -> reverse-proxy (nginx:80) -> api:8000 (/transfers, /health, /metrics)
api -> db (postgres:5432) : INSERT transfers + transfer_outbox (одна транзакция)
outbox -> rabbitmq (transfers durable) : {"transfer_id"} + publisher confirms
worker -> db FOR UPDATE (строка трансфера, фильтр PENDING в коде после лока) -> mock-provider:9443/payouts (mTLS-ish, verify /certs/cert.pem) -> UPDATE COMPLETED
worker -x-> transfers.dlq (poison/LookupError сразу, retriable max-retries 5 с экспоненциальным backoff min(2^retry,16s), prefetch=1)
prometheus:9090 <- api:8000/metrics, worker:8001/health+metrics, outbox:8002/health+metrics, rabbitmq:15692 (queue depth/consumers), mock-provider:9443/metrics (cert expiry), alert-sink:8080/metrics
alertmanager:9093 <- prometheus -> alert-sink:8080 (локальный webhook; внешний pager — замена URL)
vault:8200 -> seed/render (exec) -> runtime.<env>.env (POSTGRES_PASSWORD, RABBITMQ_DEFAULT_PASS, PROVIDER_API_KEY)
```

Поток деплоя: `flock → dirty-tree check → render-env --strict → build → up db → db-auth-check → pre-migration backup → migrator (advisory lock/checksums/timeouts) → up api/worker/outbox (compose.<env>.yml overlay) → wait healthy → smoke.sh → version записывается в .deploy-state-<env> + .deploy-history-<env>`. Версия: `APP_VERSION` → git SHA → `VERSION` → `nogit-<UTC>`; stage/prod — разные compose-проекты, runtime-файлы и backup-каталоги. Откат: только код, схема forward-only (автооткат не чинит сломанную миграцию); ручной откат обновляет state.
Переводы: `POST /transfers` требует `Idempotency-Key`; API коммитит `transfers` + `transfer_outbox` одной транзакцией, а отдельный `outbox`-сервис публикует с publisher confirms. Поэтому `/ready` проверяет только БД: при падении RabbitMQ API продолжает принимать переводы в outbox, а `/health` показывает broker down.
Health: api `/ready` (DB), worker/outbox `/health` (consumer/relay ready + `/metrics`), reverse-proxy `/healthz`, Prometheus/Alertmanager `/-/healthy`, alert-sink `/health`. Все сервисы с healthcheck участвуют в `up --wait`.
DLQ: poison/retry → `transfers.dlq`; глубина видна через RabbitMQ Prometheus plugin, `DlqNonEmpty` держится пока очередь непустая; `scripts/dlq-replay.sh` возвращает сообщения с сбросом retry-заголовков.
Наружу из base — только proxy; stage дополнительно `127.0.0.1:15672/9090`, prod — ничего лишнего (9093 alertmanager тоже не публикуется, как и 9090). `/metrics` наружу через proxy не отдается (`404`), Prometheus скрапит `api:8000`/`worker:8001` по внутренней сети.

Границы доверия: интернет→proxy (единственная точка входа); api/worker/outbox/db/rabbit — внутри compose-сети; секреты только из Vault→`runtime.<env>.env` (0600, не в образе/логах, не в git); provider — внешняя граница (API-key + Idempotency-Key + TLS verify). Stage/prod не разделяют контейнеры, тома и секреты: проекты `payment-stack-stage`/`payment-stack-prod`.
Не-цели: настоящий Vault HA, TLS на входе, external registry (GHCR по SHA собирается/пушится в cd, deploy по умолчанию локальный build), PITR/offsite backup.
