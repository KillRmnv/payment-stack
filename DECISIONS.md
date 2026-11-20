# DECISIONS

- Base compose + `compose.stage/prod.yml` (только дельты) — убран дрейф `postgres:13 vs latest`, прямой порт `8000` в prod.
- Пины `tag@digest` (раздел 0 плана, сняты `buildx imagetools inspect` 2026-11-20): воспроизводимость > удобство обновлений. Обновление = тег+digest парой.
- Multi-stage `builder→runtime`, `USER 10000`, `.dockerignore`, `requirements==` — образы меньше, нет apt-дрейфа, не-root.
- Мигратор one-shot + `pg_advisory_lock`, убран из entrypoint — нет гонки реплик. Forward-only: откат кода не трогает схему (003 с DROP уже опасна, дальше только expand/contract).
- Vault fail-fast: пустой секрет = `exit 1`, сервисы не стартуют с пустыми паролями. `.env` удален из git.
- `down -v` запрещен (`make no-destructive` + CI-чек). Деплой идемпотентный + `smoke.sh` + `LAST_GOOD_VERSION` автооткат.
- Два workflow: `ci.yml` (lint/test/compose) на PR + `cd.yml` (build GHCR SHA + Trivy fs) — чинится self-hosted/ release-prod.
- Worker: `PoisonMessage→DLQ сразу`, retriable→retry x5→DLQ, метки `processed/duplicate/poison/retry/dlq`. `verify=/certs/cert.pem` вместо `verify=False`.
- Health: `/health`+`/ready` проверяют DB+broker ping; метрики `pending/oldest_pending`, latency histogram.
- Алерты с порогами: `down 2m` (не флэп), `p99>1s 5m`, `oldest_pending>300s 5m`, `MetricsStale absent 5m` (молчание ≠ ок).
- Бэкап `payments` (был `postgres`), gzip + verify в temp DB.

## ИИ
- Muse Spark 1.3: scaffold compose/Dockerfile/CI/алерты/доки, разбор consumer/provider/migrate.
- Где ошибся и как заметил: 1) сначала оставил `curl` в healthcheck для slim — заметил при ревью (curl нет) → заменил на `python urllib`; 2) предлагал `verify=False` оставить — поймал grep'ом серты без пользы → включил `verify`; 3) digest из `sha256sum --raw` путал с manifest digest — перепроверил `imagetools inspect | grep Digest`.
