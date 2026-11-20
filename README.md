# Payment Stack (prod-ready)

## Быстрый старт с нуля (Docker + Compose v2 + Git + make + интернет)

```bash
export DB_PASSWORD=$(openssl rand -hex 16)
export RABBITMQ_PASSWORD=$(openssl rand -hex 16)
export PROVIDER_API_KEY=$(openssl rand -hex 16)
export VAULT_DEV_ROOT_TOKEN=$(openssl rand -hex 16)

make deploy ENV=stage
./scripts/smoke.sh stage
curl http://localhost:8080/health
```

Prod: `make deploy ENV=prod` (порт 8081). Требуется `curl`/`python3` для smoke.

## Команды

- `make deploy ENV=stage|prod` — идемпотентный деплой (migrate → up → smoke, автооткат кода)
- `make rollback ENV=stage VERSION=<sha>` — откат кода (схема только вперед!)
- `make backup / make restore FILE=...` — бэкап `payments` (sha256 + retention) + проверка восстановления
- `make ci` — локальные lint+test+build; полный CI в `.github/workflows/ci.yml` + `cd.yml`
- `./scripts/status.sh [stage|prod]` — статусы, health, ключевые метрики

Секреты: источник — Vault `secret/payment-stack/<env>`. Нет секрета → `render-env.sh --strict` падает с `FATAL`, сервисы не стартуют. Ротация: `seed.sh <env> --force`. `deploy/runtime.env` не коммитить (есть только `runtime.env.example`).
Компоуз: `docker-compose.yml + compose.<env>.yml` (stage открывает 15672/9090 только на 127.0.0.1, prod — ничего лишнего).
Миграции: `migrator` one-shot до раскатки, advisory lock, откат схемы не поддерживается (автооткат чинит только код).
CI proof: `docs/ci-proof.md`.
Дашборд: `monitoring/dashboard.json` (uid `payments-10s`), алерты `monitoring/alerts.yml` (доставка в Alertmanager не настроена).
Подробно: `docs/ARCHITECTURE.md`, `docs/RUNBOOK.md`, `docs/DECISIONS.md`, `docs/ASSUMPTIONS.md`, `docs/LIMITS.md`.
