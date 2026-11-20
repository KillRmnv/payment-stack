# LIMITS

- Нет Vault HA, ротации секретов на лету, owner — ручной `seed`.
- Нет blue-green/canary — rolling `up --wait` + smoke; даунтайм на миграциях с lock возможен секунды.
- Нет внешнего Alertmanager (алерты только в `alerts.yml`, webhook не настроен).
- Нет e2e нагрузки, chaos-тестов, SBOM-подписи образов.
- Dashboard `monitoring/dashboard.json` — черновик (4 панели), не импортирован в CI.
- Registry GC, retention тегов, secrets-scan в CI — не настроены.
- `reporting-ui` из стартера удален как дрейф — вернуть при нужде отдельным overlay.
