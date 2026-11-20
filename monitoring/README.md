# Monitoring

## Dashboard `dashboard.json` (uid `payments-10s`)
Валидный Grafana-импорт (schemaVersion 39): 4 панели success-rate (2xx/all, alert <0.99), pending count (>100), oldest pending (>300s), worker poison/retry/dlq rate + `worker_dlq_published_total`.

Импорт за 10 секунд:
1. Grafana → Dashboards → New → Import → загрузить `dashboard.json` (datasource uid `prometheus`).
2. Или provisioning: положить файл в `/etc/grafana/provisioning/dashboards/` + yaml-провайдер с `allowUiUpdates: true`.
Автоимпорта в этом репо нет (см. `docs/LIMITS.md`).

## Alerts `alerts.yml`
Пороги: `ApiDown/WorkerDown 2m`, `ApiHighLatency p99>1s 5m` (latency POST+GET), `PoisonQueueGrowing/DlqNonEmpty(poison|dlq) 2m`, `OldestPendingTooOld >300s 5m`, `MetricsStaleApi/MetricsStaleWorker absent(up==1) 5m` + `MetricsStaleBusiness absent(gauges) 5m`.

## Alertmanager `alertmanager.yml`
В compose поднят `alertmanager:9093`, prometheus уже шлет туда алерты. Receiver по умолчанию `blackhole` (алерты видны в `/api/v1/alerts` + Alertmanager UI). Свой webhook: заменить receiver в `alertmanager.yml`.
