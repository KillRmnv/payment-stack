# Monitoring

## Dashboard `dashboard.json` (uid `payments-10s`)
4 панели: success-rate (2xx/all, alert <0.99), pending count (>100), oldest pending (>300s), worker poison/retry/dlq rate.

Импорт за 10 секунд:
1. Grafana → Dashboards → New → Import → загрузить `dashboard.json`.
2. Или provisioning: положить файл в `/etc/grafana/provisioning/dashboards/` + yaml-провайдер с `allowUiUpdates: true`.
Автоимпорта в этом репо нет (см. `docs/LIMITS.md`).

## Alerts `alerts.yml`
Пороги: `ApiDown/WorkerDown 2m`, `ApiHighLatency p99>1s 5m`, `PoisonQueueGrowing/DlqNonEmpty 2m`, `OldestPendingTooOld >300s 5m`, `MetricsStaleApi/MetricsStaleWorker absent(up==1) 5m`.
Доставка в Alertmanager не настроена — смотреть `Prometheus UI /api/v1/alerts`.
