# LIMITS

- Нет Vault HA, ротации секретов на лету (только ручной `seed.sh --force`), прод-Vault — за рамками.
- Нет blue-green/canary — rolling `up --wait` + smoke; даунтайм на миграциях с lock возможен секунды. Автооткат чинит только код, не схему.
- Нет внешнего Alertmanager (алерты только в `alerts.yml` + Prometheus UI `/api/v1/alerts`, webhook не настроен).
- Хост с VPN/файрволом может не доставать до published-портов (host→bridge режется): для таких стендов — `scripts/smoke-net.sh` и диагностика только `docker compose exec` изнутри сети. На защите без VPN это не проявляется.
- Нет e2e нагрузки, chaos-тестов, SBOM-подписей образов.
- Dashboard `monitoring/dashboard.json` — 4 панели с порогами (success-rate/pending/oldest/dlq-rate), uid `payments-10s`; автоимпорта в Grafana нет.
- Registry GC, retention тегов, secrets-scan в CI — не настроены.
- Cron бэкапа — на хосте (`0 * * * * make backup`), cron-файла в репо нет; retention локально `KEEP_DAYS=14`, шифрования дампов нет.
- `reporting-ui` из стартера удален как дрейф — вернуть при нужде отдельным overlay.
