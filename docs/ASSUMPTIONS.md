# ASSUMPTIONS

- Registry: GHCR `ghcr.io/<owner-lower>/payment-api:<sha>` (+worker/mock-provider); локально `northwind/payment-*:dev`. Версия = git SHA, `APP_VERSION` пробрасывается в compose. `deploy.sh` по умолчанию собирает локально; pull из GHCR — отдельным шагом (разрыв зафиксирован, не скрываем).
- Vault dev-режим достаточен для стенда; прод-Vault (HA/Raft) — за рамками, но интерфейс `seed [--force] → render --strict` сохранится.
- `003_add_amount_minor` уже применена везде — считаем базовым состоянием, но признаем: `DROP COLUMN amount` был не expand/contract и необратим. Новые миграции только backward-compatible.
- `client_ip` храним в БД, но наружу по API не отдаем (PII-риск: без auth любой мог читать чужое через `GET /transfers/{id}`). Маскирование вместо чистки — совместимость тестов/consumer сохранена.
- Сеть по умолчанию bridge от compose; TLS на входе (443) не делаем — за proxy выше по уровню. Наружу из base — только proxy `${API_PORT}:80`; debug-порты только в stage на loopback.
- `mock-provider` — stand-in внешнего провайдера; контракт `POST /payouts → {payout_id,status}` достаточен. Идемпотентность по `Idempotency-Key` только в памяти: рестарт мока сбрасывает `state.payouts`, повтор даст новый `payout_id` (для мока ок, в проде так нельзя). `/admin/fail-mode` закрыт ключом `X-Api-Key/X-Admin-Key = PROVIDER_API_KEY`.
- `seed.sh` без `--force` идемпотентен (не затирает ключ) — ротация только через `--force`; `--strict` в `render-env.sh` отбрасывает слабые плейсхолдеры.
- Чистая машина = Docker Compose v2 + Git + make + интернет (по заданию). `curl`/`python3` на хосте опциональны: host-smoke их требует, без них `deploy.sh`/`rollback.sh` сами переключаются на in-network `smoke-net.sh` (python внутри контейнера). `openssl` тоже опционален: генерация секретов fallback `openssl → python3 → /dev/urandom`.
