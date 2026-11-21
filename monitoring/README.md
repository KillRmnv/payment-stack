# Monitoring

## Dashboard `dashboard.json` (uid `payments-10s`)
10 панелей:
- transfer success rate (transfers-only 2xx/all, fixed denominator);
- pending count;
- oldest pending;
- worker poison/retry/dlq rate + `worker_dlq_published_total`;
- queue depth `transfers` / `transfers.dlq`;
- outbox pending/oldest/publish errors;
- DB/broker health (`api_db_up`, `api_broker_up`);
- API p99 latency (transfers);
- transfers by status (`api_transfers`);
- backup age (`backup_age_seconds`).

Импорт: Grafana → Dashboards → New → Import → загрузить `dashboard.json` (datasource uid `prometheus`) или provisioning в `/etc/grafana/provisioning/dashboards/` + yaml-провайдер с `allowUiUpdates: true`. Автоимпорта/Grafana в этом репо нет (см. `docs/LIMITS.md`).

## Alerts `alerts.yml`
- `Watchdog` (always firing) + `AlertSinkDown` — dead man's switch и доставка.
- `ApiDown/WorkerDown/RabbitMQDown/OutboxDown 2m`, `DbDown/BrokerDown 2m`, `WorkerNotReady/OutboxNotReady 2m`.
- `ApiHighLatency` (transfers p99 >1s 5m), `ApiSuccessRateLow`, `PendingHigh`.
- `DlqNonEmpty` (глубина `transfers.dlq >0`), `PoisonQueueGrowing`, `TransferQueueBacklog`.
- `OutboxStale/OutboxPendingHigh/OutboxPublishErrors/OrphanPending`.
- `OldestPendingTooOld`, `MetricsStaleApi/MetricsStaleWorker/MetricsStaleBusiness`.
- `BackupMissing/BackupStale`, `ProviderDown/ProviderFailing/ProviderCertMissing/ProviderCertExpiry`.

## RabbitMQ metrics
Официальный `rabbitmq_prometheus` plugin включён через `deploy/rabbitmq/enabled_plugins`, per-queue labels — через `deploy/rabbitmq/rabbitmq.conf` (`prometheus.return_per_object_metrics = true`). Prometheus скрапит `rabbitmq:15692` по внутренней сети; порт наружу не публикуется. Метрики: `rabbitmq_queue_messages{queue=...}`, `rabbitmq_queue_consumers{queue=...}`.
DLQ разбирается `make dlq-replay ENV=stage ARGS="--dry-run"`.

## Outbox / backup / cert metrics
- outbox `/health` + `/metrics` на `:8002`: `outbox_pending`, `outbox_oldest_seconds`, `outbox_orphan_pending`, `outbox_publish_errors_total`, `outbox_sent_total`, `outbox_backfilled_total`.
- `backup.sh` пишет `.metrics/backup-<env>.prom`; outbox отдаёт `backup_last_success_timestamp_seconds`, `backup_last_size_bytes`, `backup_age_seconds`.
- mock-provider `/metrics` (HTTPS) отдаёт `provider_cert_expiry_seconds`, `provider_failing`.
Проверки: `make outbox-drill ENV=stage`, `make alert-selftest ENV=stage`.

## Healthchecks
`api /ready`, `worker/outbox /health`, `reverse-proxy /healthz`, Prometheus/Alertmanager `/-/healthy`, alert-sink `/health`, db/rabbit/vault/mock-provider — свои healthcheck'и. `deploy.sh` использует `up --wait`, поэтому мониторинг тоже участвует в готовности деплоя.

## Alertmanager
`alertmanager:9093` доставляет в `alert-sink:8080/alerts` (локальный webhook), `Watchdog` всегда горит. Внешний pager/email подключается заменой URL в `monitoring/alertmanager.yml`; `AlertSinkDown` ловит падение sink. Deploy перезагружает Prometheus, Alertmanager и nginx.
