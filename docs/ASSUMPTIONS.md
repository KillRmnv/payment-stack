# ASSUMPTIONS

- Registry: GHCR `ghcr.io/<owner-lower>/payment-api:<sha>` (+worker/mock-provider); локально `northwind/payment-*:dev`. Версия = git SHA, `APP_VERSION` пробрасывается в compose. `deploy.sh` по умолчанию собирает локально; pull из GHCR — отдельным шагом (разрыв зафиксирован, не скрываем).
- Vault dev-режим достаточен для стенда; прод-Vault (HA/Raft) — за рамками, но интерфейс `seed [--force] → render --strict` сохранится.
- `003_add_amount_minor` уже применена везде — считаем базовым состоянием, но признаем: `DROP COLUMN amount` был не expand/contract и необратим. Новые миграции только backward-compatible.
- `client_ip` храним как есть (PII-риск зафиксирован, не чистим ради совместимости тестов).
- Сеть по умолчанию bridge от compose; TLS на входе (443) не делаем — за proxy выше по уровню. Наружу из base — только proxy `${API_PORT}:80`; debug-порты только в stage на loopback.
- `mock-provider` — stand-in внешнего провайдера; контракта `POST /payouts → {payout_id,status}` достаточно.
- `seed.sh` без `--force` идемпотентен (не затирает ключ) — ротация только через `--force`; `--strict` в `render-env.sh` отбрасывает слабые плейсхолдеры.
- Чистая машина = Docker Compose v2 + Git + make + интернет (по заданию) + `curl/python3` для smoke (зафиксировано в README).
