"""Outbox relay: publishes committed transfers to RabbitMQ exactly once.

The API only writes `transfers` + `transfer_outbox` in one DB transaction.
This process is the only producer in the normal path; it uses publisher
confirms and retries with backoff. If it crashes after a confirmed publish but
before marking SENT, the worker processes the duplicate idempotently.
"""

import json
import logging
import os
import time

import pika
import psycopg
from prometheus_client import Counter, Gauge

from .config import load_settings
from .healthserver import HealthState, start_health_server

# OUTBOX_QUEUE is an escape hatch for drills against a scratch queue; production
# uses the default "transfers".
QUEUE = os.environ.get("OUTBOX_QUEUE", "transfers")
BATCH_SIZE = 20
METRICS_PORT = 8002

log = logging.getLogger("outbox")
PENDING = Gauge("outbox_pending", "Transfers waiting in transfer_outbox")
OLDEST = Gauge("outbox_oldest_seconds", "Age of the oldest pending outbox row")
ORPHAN = Gauge("outbox_orphan_pending", "PENDING transfers without an outbox row")
PUBLISH_ERRORS = Counter("outbox_publish_errors_total", "Outbox publish failures")
SENT = Counter("outbox_sent_total", "Outbox rows published and marked SENT")
BACKFILLED = Counter("outbox_backfilled_total", "PENDING transfers backfilled into outbox")
READY = Gauge("outbox_ready", "Outbox relay has DB/Rabbit connections and is looping")
BACKUP_TS = Gauge(
    "backup_last_success_timestamp_seconds", "Unix time of the last successful backup"
)
BACKUP_SIZE = Gauge("backup_last_size_bytes", "Size of the last backup archive")
BACKUP_AGE = Gauge("backup_age_seconds", "Age of the last successful backup")
HEALTH = HealthState()


def backoff_seconds(attempts):
    # Cap the exponent before computing it: attempts come from the DB and can
    # grow indefinitely while RabbitMQ is down.
    return min(2 ** min(max(0, attempts), 6), 60)


def rabbit_channel(settings):
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(
            host=settings.rabbitmq_host,
            credentials=credentials,
            socket_timeout=5,
            blocked_connection_timeout=30,
        )
    )
    channel = connection.channel()
    channel.queue_declare(queue=QUEUE, durable=True)
    channel.confirm_delivery()
    return connection, channel


def reconcile(conn):
    """Backfill PENDING transfers created by an older API during rolling deploy."""
    with conn.transaction():
        cursor = conn.execute(
            """
            INSERT INTO transfer_outbox (transfer_id, payload)
            SELECT t.id, jsonb_build_object('transfer_id', t.id)
            FROM transfers t
            LEFT JOIN transfer_outbox o ON o.transfer_id = t.id
            WHERE t.status = 'PENDING'
              AND o.id IS NULL
              AND t.created_at < now() - interval '1 minute'
            ON CONFLICT (transfer_id) DO NOTHING
            """
        )
        count = cursor.rowcount
    if count:
        BACKFILLED.inc(count)
        log.info("backfilled %s pending transfers into outbox", count)


def update_gauges(conn):
    with conn.transaction():
        row = conn.execute(
            """
            SELECT
              (SELECT count(*) FROM transfer_outbox WHERE status = 'PENDING'),
              (SELECT COALESCE(EXTRACT(EPOCH FROM (now() - min(created_at))), 0)
                 FROM transfer_outbox WHERE status = 'PENDING'),
              (SELECT count(*)
                 FROM transfers t
                 LEFT JOIN transfer_outbox o ON o.transfer_id = t.id
                WHERE t.status = 'PENDING' AND o.id IS NULL)
            """
        ).fetchone()
    PENDING.set(row[0] or 0)
    OLDEST.set(float(row[1] or 0))
    ORPHAN.set(row[2] or 0)


def update_backup_metrics():
    """Read the host-written backup textfile; missing file is reported as -1."""
    path = os.environ.get(
        "BACKUP_METRICS_FILE", f"/metrics/backup-{os.environ.get('STACK_ENV', 'stage')}.prom"
    )
    timestamp = 0
    size = 0
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                if line.startswith("backup_last_success_timestamp_seconds "):
                    timestamp = int(float(line.split(None, 1)[1]))
                elif line.startswith("backup_last_size_bytes "):
                    size = int(float(line.split(None, 1)[1]))
    except OSError:
        pass
    BACKUP_TS.set(timestamp)
    BACKUP_SIZE.set(size)
    BACKUP_AGE.set(time.time() - timestamp if timestamp else -1)


def process_batch(conn, channel):
    with conn.transaction():
        rows = conn.execute(
            """
            SELECT id, payload, attempts
            FROM transfer_outbox
            WHERE status = 'PENDING' AND next_attempt_at <= now()
            ORDER BY next_attempt_at, created_at
            FOR UPDATE SKIP LOCKED
            LIMIT %s
            """,
            (BATCH_SIZE,),
        ).fetchall()

        for row_id, payload, attempts in rows:
            try:
                # pika raises NackError/UnroutableError/AMQPError on confirm
                # failure and returns None on success.
                confirmed = channel.basic_publish(
                    exchange="",
                    routing_key=QUEUE,
                    body=json.dumps(payload).encode(),
                    properties=pika.BasicProperties(delivery_mode=2),
                )
                if confirmed is False:
                    raise RuntimeError("publish was not confirmed by RabbitMQ")
            except Exception as exc:  # noqa: BLE001 — per-row retry, never ack/lose
                PUBLISH_ERRORS.inc()
                delay = backoff_seconds(attempts)
                conn.execute(
                    """
                    UPDATE transfer_outbox
                    SET attempts = attempts + 1,
                        next_attempt_at = now() + make_interval(secs => %s),
                        last_error = %s
                    WHERE id = %s
                    """,
                    (delay, str(exc)[:500], row_id),
                )
                log.warning("publish failed outbox_id=%s attempts=%s: %s", row_id, attempts, exc)
                if isinstance(exc, (pika.exceptions.AMQPError, OSError)):
                    break
                continue

            conn.execute(
                """
                UPDATE transfer_outbox
                SET status = 'SENT', sent_at = now(), attempts = attempts + 1,
                    last_error = NULL
                WHERE id = %s
                """,
                (row_id,),
            )
            SENT.inc()
            log.info("sent outbox_id=%s transfer_id=%s", row_id, payload.get("transfer_id"))


def main():
    settings = load_settings()
    logging.basicConfig(
        level=settings.log_level, format="%(asctime)s %(levelname)s %(name)s %(message)s"
    )
    start_health_server(METRICS_PORT, HEALTH)
    log.info("outbox relay started")

    conn = None
    rabbit = None
    channel = None
    while True:
        try:
            if conn is None or conn.closed:
                conn = psycopg.connect(settings.dsn, connect_timeout=5)
            if channel is None or channel.is_closed:
                if rabbit is not None:
                    rabbit.close()
                rabbit, channel = rabbit_channel(settings)
                log.info("rabbitmq confirmed channel ready")

            reconcile(conn)
            process_batch(conn, channel)
            update_gauges(conn)
            update_backup_metrics()
            if channel.is_closed:
                raise RuntimeError("RabbitMQ channel closed during publish")
            READY.set(1)
            HEALTH.ready = True
            HEALTH.detail = "publishing"
            time.sleep(1)
        except KeyboardInterrupt:
            break
        except Exception:
            READY.set(0)
            HEALTH.ready = False
            HEALTH.detail = "reconnecting"
            log.exception("outbox loop failed; reconnecting")
            try:
                if channel is not None and channel.is_open:
                    channel.close()
                if rabbit is not None and rabbit.is_open:
                    rabbit.close()
            except Exception:
                log.debug("ignoring error while closing outbox connections", exc_info=True)
            if conn is not None:
                conn.close()
            conn = None
            rabbit = None
            channel = None
            time.sleep(5)

    if channel is not None:
        channel.close()
    if rabbit is not None:
        rabbit.close()
    if conn is not None:
        conn.close()


if __name__ == "__main__":
    main()
