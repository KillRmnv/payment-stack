# CI proof

## Current pipeline (2026-11-21)

- Pipeline: `.github/workflows/pipeline.yml`
- Last recorded run (before `deploy-smoke` was added): https://github.com/KillRmnv/payment-stack/actions/runs/44895832507 — success
  - `test` — lint, compose stage+prod, no-destructive, promtool/amtool/nginx, actionlint, api/worker tests
  - `build-scan-push` — 3 images full+short SHA, Trivy image scans, GHCR push, release artifact
  - `deploy-stage`/`deploy-prod` — skipped: repository has no self-hosted `stage`/`prod` runners and `STAGE_DEPLOY_ENABLED`/`PROD_DEPLOY_ENABLED` are not set
- **Added after that run:** `deploy-smoke` on `ubuntu-latest` (push to `main`, not PR). It runs `./scripts/deploy-smoke.sh`: clean `make deploy ENV=stage`, `smoke-idempotency`, `alert-selftest`, `restore-apply-selftest`, `outbox-drill`. This is the Level 2 proof on HEAD; it does not replace self-hosted stage/prod deployment.
- `deploy-stage`/`deploy-prod` still require self-hosted runners, `*_DEPLOY_PATH`, and `*_DEPLOY_ENABLED`; without them those jobs skip. Prod can run when stage is intentionally skipped, but a failed stage or build blocks prod.

## HEAD deploy-smoke (local equivalent, 2026-11-21)

Run in a disposable copy/`ci-proof` project with remapped ports (the legacy `deploy` stand still owns 8080/9090/15672). Same HEAD code, no `.git` (ZIP-like), generated secrets:

```text
$ ./scripts/deploy-smoke.sh
deploy-smoke: project=ci-proof runtime=runtime.ci-proof.env
smoke OK
deploy OK 1.0.0
deploy-smoke: idempotency
idempotency smoke OK
deploy-smoke: alert delivery
sent SelfTest ... to Alertmanager
... SelfTest delivered to alert-sink
alert delivery OK
deploy-smoke: restore --apply regression
current-schema apply OK
pre-004 apply + 004 OK
broken dump left the target intact
restore apply selftest OK
deploy-smoke: outbox drill
outbox drill OK
deploy-smoke OK
```

Also verified after the drill: api/worker/outbox/mock-provider all `1.0.0`, alert-sink user `65534:65534`, provider cert ~364 days left.
`make restore --apply` on a live dump also passed (`restore --apply OK`), and `make outbox-drill` restored the exact deployed version.

## Historical proof (local, 2026-11-20)

> The log below is for commit `64d1999`; it is kept for history and is not proof for the current HEAD.


Machine: Linux + Docker 29.10.0 + Compose v5.8.0, Python 3.12, commit `64d1999`, `2026-11-20T19:40:42Z`.
Full GitHub Actions: `.github/workflows/ci.yml` (lint/test/compose stage+prod) + `cd.yml` (build 3 images GHCR :sha + Trivy image scan + push).

Repo: `https://github.com/KillRmnv/payment-stack` (private). Runs (доказательство вместо `act`):
- `ci` #44814476855 ✅ 20s — lint/test/compose (после пина `ruff==0.17.6`)
- `cd` #44814476857 ✅ 1m19s — build 3 образов `:ef4fc31`, Trivy HIGH/CRITICAL fixable-only, push в `ghcr.io/killrmnv/*` (digest `sha256:5b22da...`)
По пути поймано и починено вживую: ruff-strict (BLE/S110/I001, 9 ошибок), `trivy-action@0.24.0` не резолвится (пин SHA `a9c7b0f0` = v0.36.0), uppercase owner для GHCR, `docker images` с 3 аргументами, реальные CVE (starlette 0.37.2 → bump до 1.10.0 + uvicorn/pika/psycopg/requests/prometheus-client).

## Current unit tests (2026-11-21)

```text
PYTHONPATH=services/api pytest services/api/tests -q    -> 25 passed
PYTHONPATH=services/worker pytest services/worker/tests -q -> 32 passed
ruff check services mock-provider monitoring           -> All checks passed
ruff format --check ...                                -> 26 files already formatted
```

## pytest api (8 passed, historical)
```
........                                                           [100%]
8 passed in 0.02s
```
`PYTHONPATH=services/api pytest services/api/tests -q`

## pytest worker (5 passed, historical)
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
Ручной тест на disposable-хосте со свежими томами (не скрипт деплоя) → `make deploy ENV=stage`: vault→seed→render --strict→build→migrator→up (8/8 Healthy)→db-auth-check→smoke. Хост-стенд за VPN: host→bridge режется, `deploy.sh` сам переключился на `smoke-net.sh`.
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
