# ARCHITECTURE

```
client -> reverse-proxy (nginx:80) -> api:8000 (/transfers, /health, /metrics)
api -> db (postgres:5432) : INSERT PENDING
api -> rabbitmq (transfers durable) : {"transfer_id"}
worker -> db FOR UPDATE (строка трансфера, фильтр PENDING в коде после лока) -> mock-provider:9443/payouts (mTLS-ish, verify /certs/cert.pem) -> UPDATE COMPLETED
worker -x-> transfers.dlq (poison/LookupError сразу, retriable max-retries 5 с экспоненциальным backoff min(2^retry,16s), prefetch=1)
prometheus:9090 <- api:8000/metrics, worker:8001 (+ alertmanager:9093 scrape)
alertmanager:9093 <- prometheus (доставка по умолчанию blackhole, свой receiver в monitoring/alertmanager.yml)
vault:8200 -> seed/render (exec) -> runtime.env (POSTGRES_PASSWORD, RABBITMQ_DEFAULT_PASS, PROVIDER_API_KEY)
```

Поток деплоя: `render-env --strict → migrator (advisory lock) → up api/worker (compose.<env>.yml overlay) → wait healthy → smoke.sh → LAST_GOOD_VERSION`. Откат: только код, схема forward-only (автооткат не чинит сломанную миграцию).
Наружу из base — только proxy; stage дополнительно `127.0.0.1:15672/9090`, prod — ничего лишнего (9093 alertmanager тоже не публикуется, как и 9090).

Границы доверия: интернет→proxy (единственная точка входа); api/worker/db/rabbit — внутри compose-сети; секреты только из Vault→runtime.env (не в образе/логах, `runtime.env` не в git); provider — внешняя граница (API-key + Idempotency-Key + TLS verify).
Не-цели: настоящий Vault HA, TLS на входе, external registry (GHCR по SHA собирается/пушится в cd, deploy по умолчанию локальный build).
