# LIMITS

- `003_add_amount_minor` с `DROP COLUMN amount` уже необратима (не expand/contract) — считаем базовым состоянием. Откат кода до pre-003 невозможен; дальше только backward-compatible миграции + forward-фиксы `004_...`.
- Нет Vault HA, ротации секретов на лету (только ручной `deploy/vault/rotate.sh <env>` без потери данных); прод-Vault — за рамками.
- Нет blue-green/canary — rolling `up --wait` + smoke; даунтайм на миграциях с lock возможен секунды. Автооткат чинит только код, не схему.
- Нет внешнего Alertmanager-канала (webhook/pager): в compose поднят `alertmanager:9093` с `blackhole` receiver по умолчанию, prometheus уже шлет туда алерты. Свой receiver — в `monitoring/alertmanager.yml` (заменить blackhole на webhook).
- Хост с VPN/файрволом может не доставать до published-портов (host→bridge режется): для таких стендов — `scripts/smoke-net.sh` и диагностика только `docker compose exec` изнутри сети. На защите без VPN это не проявляется.
- Нет e2e нагрузки, chaos-тестов, SBOM-подписей образов.
- Dashboard `monitoring/dashboard.json` — валидный Grafana-импорт (schemaVersion 39, uid `payments-10s`): 4 панели с порогами (success-rate/pending/oldest/dlq-rate); импорт — `monitoring/README.md` (Provisioning или UI import).
- Registry GC, retention тегов — не настроены; secrets-scan в CI — только Trivy image/fs, без подписей.
- Cron бэкапа — `deploy/backup.cron` на хосте (`0 * * * * make backup`), retention локально `KEEP_DAYS=14`, шифрования дампов нет.
- `reporting-ui` из стартера удален как дрейф — вернуть при нужде отдельным overlay.
- Retry без blocking sleep: немедленная републикация (prefetch=1 + roundtrip через брокер гасят hot-loop). Экспоненциальный backoff с jitter — только через DLX/TTL, здесь осознанно не делаем.
- `worker_dlq_published_total` — Counter опубликованных в DLQ (бывший `worker_dlq_depth` Gauge врал после ручной чистки DLQ).
