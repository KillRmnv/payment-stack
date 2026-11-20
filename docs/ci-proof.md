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
