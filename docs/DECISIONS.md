# DECISIONS

- Base compose + `compose.stage/prod.yml` (только дельты, подключаются через `-f` в `Makefile`/`deploy.sh`/`rollback.sh`/`ci.yml`). Base ничего не публикует наружу кроме proxy; stage открывает `15672/9090` только на `127.0.0.1`, prod — ничего лишнего.
- Пины `tag@digest` (сняты `buildx imagetools inspect` 2026-11-20): воспроизводимость > удобство обновлений. Обновление = тег+digest парой.
- Multi-stage `builder→runtime`, `USER 10000`, `.dockerignore`, `requirements==` — образы меньше, нет apt-дрейфа, не-root.
- Мигратор one-shot + `pg_advisory_lock`, убран из entrypoint — нет гонки реплик. Forward-only: откат кода не трогает схему (003 с DROP уже опасна, дальше только expand/contract).
- Vault fail-fast: пустой секрет = `exit 1`, сервисы не стартуют с пустыми паролями. `runtime.env` в git не коммитится (только `runtime.env.example`, см. `.gitignore`), генерируется из Vault; `--strict` отбрасывает плейсхолдеры. `seed.sh` без `--force` не затирает существующий ключ; ротация без потери данных — `vault/rotate.sh` (ALTER + rabbitmqctl + seed --force), `seed --force` напрямую — только с пониманием десинка pgdata.
- `down -v` запрещен (`make no-destructive` + CI-чек). Деплой идемпотентный: build образов внутри `deploy.sh` (лечит stale-теги), `db-auth-check` до smoke (десинк pgdata/пароли — понятный FATAL, не молчаливый 503), smoke host/in-network в `deploy.sh` и `rollback.sh` + `LAST_GOOD_VERSION` автооткат (только код `api worker`, не схема).
- Reverse-proxy резолвит api через переменную + `resolver 127.0.0.11 valid=10s`: после пересоздания api IP меняется, статичный upstream давал бы вечный 502.
- Vault dev-root токен стабилен на env (экспорт → `.vault-token-<env>` → генерация): смена токена пересоздает Vault и стирает in-memory секреты.
- Два workflow: `ci.yml` (lint/test/compose stage+prod) на PR + `cd.yml` (build 3 образов GHCR SHA + Trivy image scan api/worker/mock-provider + push).
- Worker: `PoisonMessage` и `LookupError`→DLQ сразу, retriable→retry x5 с backoff→DLQ, метки `processed/duplicate/poison/retry/dlq`, `DLQ_DEPTH.inc()` на каждой публикации в DLQ, `verify=<ca-bundle>` вместо `verify=False`, `request_id=transfer_id` в логах.
- Health: `/health`+`/ready` проверяют DB+broker ping; метрики `pending/oldest_pending`, latency histogram на всех исходах (2xx/4xx/5xx); при недоступности БД gauges уходят в NaN, чтобы не отдавать stale.
- Алерты с порогами: `down 2m` (не флэп), `poison/dlq 2m`, `p99>1s 5m`, `oldest_pending>300s 5m`, `MetricsStaleApi/MetricsStaleWorker absent(up{job}==1) 5m` (молчание ≠ ок). Alertmanager не подключен — алерты только в Prometheus UI.
- Бэкап `payments` + sha256 + retention `KEEP_DAYS=14` (`deploy/backup.cron` на хосте), verify в temp DB + `--apply` в live DB с migrator+smoke (`transfers/pending + schema_migrations`).
- Сдача без секретов: `scripts/package.sh` собирает ZIP с exclude `runtime.env/.vault-token-*/.deploy-state-*/backups/.git` + проверкой на утечку.

## ИИ
- Muse Spark 1.3: scaffold compose/Dockerfile/CI/алерты/доки, разбор consumer/provider/migrate.
- Где ошибся и как заметил: 1) сначала оставил `curl` в healthcheck для slim — заметил при ревью (curl нет) → заменил на `python urllib`; 2) предлагал `verify=False` оставить — поймал grep'ом серты без пользы → включил `verify`; 3) digest из `sha256sum --raw` путал с manifest digest — перепроверил `imagetools inspect | grep Digest`.
