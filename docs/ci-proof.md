# CI proof (local, 2026-11-20)

Machine: Linux + Docker Compose v2, Python 3.12, `make ci` equivalent.

## pytest api (8 passed)
```
........  [100%]
8 passed in 0.02s
```
`PYTHONPATH=services/api pytest services/api/tests -q`

## pytest worker (5 passed)
```
.....  [100%]
5 passed in 0.02s
```
`PYTHONPATH=services/worker pytest services/worker/tests -q`

## ruff
```
All checks passed!
```
`ruff check services mock-provider`

## compose
```
compose OK
```
`docker compose config` (base + env validation, no `down -v` per `make no-destructive`)

## Workflows
- `.github/workflows/ci.yml` — lint/test/compose on push+PR to main (ubuntu-latest)
- `.github/workflows/cd.yml` — build GHCR `:sha` + Trivy fs HIGH/CRITICAL

## docker build (2026-11-20)
```
Image northwind/mock-provider:dev Built
Image northwind/payment-api:dev Built
Image northwind/payment-worker:dev Built
```
`docker compose build api worker mock-provider` — multi-stage slim, USER 10000.
