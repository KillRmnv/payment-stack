# ASSUMPTIONS

- Registry: GHCR `ghcr.io/<owner>/payment-api:<sha>`; локально `northwind/payment-*:dev`. Версия = git SHA, `APP_VERSION` пробрасывается в compose.
- Vault dev-режим достаточен для стенда; прод-Vault (HA/Raft) — за рамками, но интерфейс `seed→render --strict` сохранится.
- `003_add_amount_minor` уже применена везде — считаем базовым состоянием, новые миграции только backward-compatible.
- `client_ip` храним как есть (PII-риск зафиксирован, не чистим ради совместимости тестов).
- Сеть по умолчанию bridge от compose; TLS на входе (443) не делаем — за proxy выше по уровню.
- `mock-provider` — stand-in внешнего провайдера; контракта `POST /payouts → {payout_id,status}` достаточно.
- Чистая машина = Docker Compose v2 + Git + make + интернет (по заданию).
