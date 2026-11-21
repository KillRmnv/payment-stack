# LIMITS

## Данные и схема

- `003_add_amount_minor` с `DROP COLUMN amount` уже необратима (не expand/contract) — считаем базовым состоянием. Откат кода до pre-003 невозможен; дальше только backward-compatible миграции + forward-фиксы `005_...`.
- `restore --apply` удаляет **все таблицы public-схемы**, но не произвольные объекты (кастомные схемы/типы/функции). Текущая схема покрыта; при появлении таких объектов restore нужно расширять. Регрессия `make restore-apply-selftest` проверяет текущий и pre-004 дампы.
- `transfers`/`transfer_outbox` без retention/партиционирования; `SENT`-строки outbox не чистятся автоматически.
- `MAX_AMOUNT_MINOR = 10^12` (10 млрд единиц валюты): суммы выше отклоняются 400. Это граница продукта, а не бесконечная поддержка BIGINT.
- Нет down-миграций; checksums фиксируют дрейф только после первого прогона мигратора.

## Деплой и CD

- `deploy-smoke` на `ubuntu-latest` реально разворачивает HEAD с нуля, гоняет smoke/idempotency/alert-selftest/restore-apply-selftest/outbox-drill и является доказательством для Level 2. Он запускается на push в `main`, не на PR. Локальный запуск использует `ENV=stage` (пишет `backups/stage` и `.metrics/stage`) — на общем хосте лучше запускать в temp-копии/с переопределёнными портами.
- Реальные `deploy-stage`/`deploy-prod` всё ещё требуют self-hosted runners, `*_DEPLOY_PATH`, `*_DEPLOY_ENABLED` и labels; без них jobs skip. `deploy-smoke` не заменяет deploy на конкретном стенде.
- Deploy собирает образы **локально** из checkout того же SHA, а не тянет просканированный GHCR digest. `build-scan-push` сканирует образы, но деплой использует локальную сборку — supply-chain разрыв зафиксирован.
- `deploy-prod` может работать при выключенном stage (skipped), но проваленный stage блокирует prod.
- `flock` (util-linux) и `bash` — обязательные зависимости deploy-скриптов. На минимальном хосте с «только Docker/Git/make» их нужно установить; fallback-лока нет.
- Deploy/rollback/rotate/restore сериализованы `flock`; dirty tree блокируется, кроме `ALLOW_DIRTY=1`. Изменения bind-mount конфигов nginx/monitoring автоматически не откатываются; nginx/prometheus/alertmanager перечитываются, alert-sink пересоздаётся, RabbitMQ — нет.
- Изменения `deploy/rabbitmq/rabbitmq.conf` и `enabled_plugins` требуют явного пересоздания/рестарта RabbitMQ; деплой их не применяет автоматически, чтобы не рвать очередь.
- Нет blue-green/canary: rolling `up --wait` + smoke, короткий даунтайм на пересоздании/миграциях возможен.

## Секреты и ротация

- Vault — dev-режим, без HA; при пересоздании/потере токена секреты надо seed'ить заново. Прод-Vault (Raft/HA) — за рамками.
- `rotate.sh` — maintenance window: останавливает api/worker/outbox/mock-provider, меняет пароли, seed/render, запускает. При ошибке пытается вернуть старые значения из Vault и поднять сервисы; это best-effort, не гарантия zero-downtime.
- `ensure_vault_token` не даёт молча заменить сохранённый токен другим env-токеном: при расхождении с `.vault-token-<env>` — FATAL. Новый токен = новый dev-Vault и потеря in-memory секретов.
- README разделяет первый запуск и повторный деплой; повторная генерация DB/Rabbit-паролей не поддерживается (для смены — `rotate.sh`).
- Сертификат mock-provider перевыпускается автоматически только при старте/рестарте контейнера, если истёк или истекает в ближайшие 30 дней. Живой ротации без рестарта нет; алерт `ProviderCertExpiry` — за 30 дней.

## Отказоустойчивость

- API принимает переводы при упавшем RabbitMQ (пишет `transfers` + outbox в БД) и теперь может стартовать без RabbitMQ; `/ready` проверяет только БД.
- Worker не содержит собственного reconnect-цикла: при потере соединения процесс завершается, Docker `restart: unless-stopped` поднимает его. `/health` worker/outbox — это readiness, а не heartbeat; зависший цикл без исключения может оставаться `ready`.
- Outbox поддерживает publisher confirms и `FOR UPDATE SKIP LOCKED`, но если сообщение потеряно после подтверждения, а outbox-строка уже `SENT`, автоматического переотправления нет; `OldestPendingTooOld` покажет застрявший перевод. `SENT` + `PENDING` reconciliation не реализован.
- Retry в consumer блокирует один worker на `min(2^retry,16s)` (prefetch=1) — осознанный компромисс; backoff с jitter через DLX/TTL не делаем.
- Нет blue-green/canary, e2e-нагрузки и chaos-тестов.

## Наблюдаемость

- Alertmanager доставляет в локальный `alert-sink`; `Watchdog` — dead man's switch. Внешнего pager/email/Slack нет; если умрёт сам Prometheus, внешнего heartbeat тоже нет.
- `alert-selftest` отправляет уникальный `SelfTest` через Alertmanager API и проверяет его в sink; старый Watchdog больше не даёт ложный зелёный. `alert-sink` работает non-root (65534).
- Alert-sink пересоздаётся при каждом deploy, поэтому изменения его кода применяются. RabbitMQ-конфиг — отдельно, см. выше.
- Dashboard — 10 панелей; success-rate считается только по POST `/transfers` (GET 404 больше не занижает). Grafana в compose нет, импорт ручной, datasource uid `prometheus` не провижинится.
- Backup age/size, cert expiry — метрики; disk usage, PITR/offsite/encryption дампов не сделаны.
- `MetricsStaleBusiness` — дополнительная защита; DB-down ловится `api_db_up`/`DbDown`, а не только отсутствием метрик.

## Бэкапы

- Backup: `payments` + sha256 + retention `KEEP_DAYS=14`, `backups/<env>/`, 0600; `--apply` делает safety-backup и verify в temp DB (место/время удваиваются). Pre-migration backup на самом первом деплое может быть пустым (схема ещё не создана); `restore --verify-only` теперь принимает такой пустой дамп как валидный pre-migration snapshot.
- Нет шифрования дампов, offsite-копии, WAL/PITR и автоматической проверки restore по расписанию.
- `deploy/backup.cron` — пример с жёстким путём `/opt/payment-stack/payment-stack-starter`; для другого пути/старого проекта (`PAYMENT_STACK_PROJECT=deploy`, `PAYMENT_STACK_RUNTIME_ENV=runtime.env`) его нужно адаптировать.

## Безопасность

- Нет authN/authZ на API: любой, кто достучался до proxy, может создать/прочитать перевод.
- TLS на ingress не делается; предполагается proxy выше по уровню.
- DB/Rabbit-пользователи приложения — admin/superuser; worker монтирует весь volume с приватным ключом mock-provider.
- API/outbox/migrator получают `PROVIDER_API_KEY` через общий runtime env, хотя ключ нужен только worker/mock-provider; least-privilege split env не сделан.
- `package.sh` сканирует token-like строки, но это эвристика по ограниченному набору расширений; `.git` в ZIP не включается (история с тестовыми `nw-test-*` остаётся вне архива).
- Registry GC/retention не настроены; pipeline делает Trivy image, но не `trivy fs/config`, secret-scan и подписи; `make scan` — локальная команда.
- Нет SBOM-подписей образов.

## Миграция старого стенда

- Переход с проекта `deploy` на `payment-stack-<env>` не автоматизирован: старые контейнеры/тома остаются, новый проект стартует с пустыми томами. Для миграции — `PAYMENT_STACK_PROJECT=deploy PAYMENT_STACK_RUNTIME_ENV=runtime.env` или ручной перенос томов.
- `reporting-ui` из стартера удалён как дрейф — вернуть при необходимости отдельным overlay.
