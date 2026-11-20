# Payment Stack (prod-ready)

## Быстрый старт с нуля (только Docker + make + интернет)

```bash
export DB_PASSWORD=$(openssl rand -hex 16)
export RABBITMQ_PASSWORD=$(openssl rand -hex 16)
export PROVIDER_API_KEY=$(openssl rand -hex 16)
export VAULT_DEV_ROOT_TOKEN=$(openssl rand -hex 16)

make deploy ENV=stage
./scripts/smoke.sh stage
curl http://localhost:8080/health
```

Prod: `make deploy ENV=prod` (порт 8081).

## Команды

- `make deploy ENV=stage|prod` — идемпотентный деплой (migrate → up → smoke, автооткат)
- `make rollback ENV=stage VERSION=<sha>` — откат кода (схема только вперед!)
- `make backup / make restore FILE=...` — бэкап `payments` + проверка восстановления
- `make ci` — локальные lint+test+build; полный CI в `.github/workflows/ci.yml` + `cd.yml`
- `./scripts/status.sh` — статусы сервисов

Секреты: источник — Vault `secret/payment-stack/<env>`. Нет секрета → `render-env.sh` падает с `FATAL`, сервисы не стартуют. `deploy/.env` не коммитить (см. `.env.example`).
Миграции: `migrator` one-shot до раскатки, advisory lock, откат схемы не поддерживается.
CI proof: `docs/ci-proof.md`.
Дашборд: `monitoring/dashboard.json`, алерты `monitoring/alerts.yml`.
Подробно: `ARCHITECTURE.md`, `RUNBOOK.md`, `DECISIONS.md`, `ASSUMPTIONS.md`, `LIMITS.md`.
