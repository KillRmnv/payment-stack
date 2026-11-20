# CI proof (local, 2026-11-20)

Machine: Linux + Docker 29.10.0 + Compose v5.8.0, Python 3.12, commit `64d1999`, `2026-11-20T19:40:42Z`.
Full GitHub Actions: `.github/workflows/ci.yml` (lint/test/compose stage+prod) + `cd.yml` (build 3 images GHCR :sha + Trivy image scan + push).

## pytest api (8 passed)
```
........                                                           [100%]
8 passed in 0.02s
```
`PYTHONPATH=services/api pytest services/api/tests -q`

## pytest worker (5 passed)
```
.....                                                              [100%]
5 passed in 0.02s
```
`PYTHONPATH=services/worker pytest services/worker/tests -q`

## ruff
```
All checks passed!
```
`ruff check services mock-provider`

## compose (stage+prod)
```
stage OK
prod OK
```
`docker compose --env-file env/stage.env -f docker-compose.yml -f compose.stage.yml config`
`docker compose --env-file env/prod.env -f docker-compose.yml -f compose.prod.yml config`
Base ничего не публикует наружу кроме proxy; stage открывает 15672/9090 только на 127.0.0.1. `make no-destructive` зелен.

## Workflows
- `.github/workflows/ci.yml` — lint/test/compose stage+prod на push+PR к main
- `.github/workflows/cd.yml` — build api/worker/mock-provider `:sha`, Trivy image HIGH/CRITICAL, push в GHCR

## docker build (2026-11-20, commit 64d1999)
```
Image northwind/payment-api:dev Built
Image northwind/payment-worker:dev Built
Image northwind/mock-provider:dev Built
```
`touch deploy/runtime.env && docker compose -f deploy/docker-compose.yml build api worker mock-provider` — multi-stage slim, USER 10000. `runtime.env` удален после сборки (не в git, есть только `runtime.env.example`).

## deploy stage с нуля (2026-11-20, commit 64d1999)
`down -v` (симуляция чистой машины) → `make deploy ENV=stage`: vault→seed→render --strict→build→migrator→up (8/8 Healthy)→db-auth-check→smoke. Хост-стенд за VPN: host→bridge режется, `deploy.sh` сам переключился на `smoke-net.sh`.
```
smoke-net: created 6001f565-... try 1 status=PENDING try 2 status=COMPLETED / smoke-net OK
api: {"status":"ok","version":"64d1999","checks":{"db":"up","broker":"up"}}
```

## учения (in-network, все PASS)
- poison JSON в `transfers` → сразу DLQ, `worker_messages_total{result="poison"} 1.0` (без retry-цикла);
- mock-provider `fail-mode enabled` → `api_pending_transfers 1.0`, `oldest_pending 12s` → fail-mode off → `COMPLETED` (retry/backoff отработал);
- `stop db` → `/health` 503 → `up db` → `ok` без потерь и без ручных миграций;
- `vault kv delete` → `render-env --strict` FATAL → `seed --force` → render OK.
Найденные по ходу баги и фиксы: stale entrypoint в кэше сборки (лечится `build` в deploy.sh), статичный nginx-upstream после пересоздания api (лечится `resolver 127.0.0.11` + переменная), десинк pgdata/пароли при смене секретов (лечится `db-auth-check` + стабильный `VAULT_DEV_ROOT_TOKEN`).
