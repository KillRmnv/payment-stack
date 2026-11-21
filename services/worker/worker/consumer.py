import logging
import time

import pika
import psycopg
from prometheus_client import Counter, Gauge

from .config import load_settings
from .healthserver import HealthState, start_health_server
from .messages import PoisonMessage, parse_message, parse_retry_count
from .money import format_minor
from .provider import ProviderProtocolError, send_payout

log = logging.getLogger("worker")
QUEUE = "transfers"
DLQ = "transfers.dlq"
MAX_RETRIES = 5
MESSAGES = Counter("worker_messages_total", "Processed messages", ["result"])
DLQ_PUBLISHED = Counter("worker_dlq_published_total", "Total messages published to DLQ")
READY = Gauge("worker_ready", "Worker consumer is connected and ready")
HEALTH = HealthState()


def process(settings, body):
    transfer_id = parse_message(body)  # raises PoisonMessage
    request_id = str(transfer_id)  # Idempotency-Key == transfer_id, сквозной request_id
    with psycopg.connect(settings.dsn) as conn:
        row = conn.execute(
            "SELECT amount_minor, currency, recipient, status FROM transfers WHERE id = %s FOR UPDATE",
            (transfer_id,),
        ).fetchone()
        if row is None:
            raise LookupError(f"transfer {transfer_id} does not exist")
        amount_minor, currency, recipient, status = row
        if status != "PENDING":
            log.info(
                "transfer_id=%s request_id=%s duplicate status=%s", transfer_id, request_id, status
            )
            return "duplicate"
        payout = send_payout(settings, transfer_id, format_minor(amount_minor), currency, recipient)
        conn.execute(
            "UPDATE transfers SET status = %s, provider_reference = %s, updated_at = now() WHERE id = %s",
            (payout["status"], payout["payout_id"], transfer_id),
        )
    log.info(
        "transfer_id=%s request_id=%s processed status=%s",
        transfer_id,
        request_id,
        payout["status"],
    )
    return "processed"


def publish_confirmed(channel, routing_key, body, headers=None):
    # pika raises NackError/UnroutableError/AMQPError when publisher confirms
    # fail and returns None on success. Some versions may return False.
    confirmed = channel.basic_publish(
        exchange="",
        routing_key=routing_key,
        body=body,
        properties=pika.BasicProperties(delivery_mode=2, headers=headers or {}),
    )
    if confirmed is False:
        raise RuntimeError(f"RabbitMQ did not confirm publish to {routing_key}")


def publish_dlq(channel, body, reason):
    channel.queue_declare(queue=DLQ, durable=True)
    publish_confirmed(channel, DLQ, body, headers={"x-death-reason": reason})
    DLQ_PUBLISHED.inc()


def main():
    settings = load_settings()
    logging.basicConfig(
        level=settings.log_level, format="%(asctime)s %(levelname)s %(name)s %(message)s"
    )
    start_health_server(8001, HEALTH)
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    connection = pika.BlockingConnection(
        pika.ConnectionParameters(host=settings.rabbitmq_host, credentials=credentials)
    )
    channel = connection.channel()
    channel.queue_declare(queue=QUEUE, durable=True)
    channel.queue_declare(queue=DLQ, durable=True)
    channel.confirm_delivery()
    channel.basic_qos(prefetch_count=1)
    READY.set(1)
    HEALTH.ready = True
    HEALTH.detail = f"consuming {QUEUE}"

    def on_message(ch, method, properties, body):
        try:
            # Headers are untrusted input. Keep this inside try: malformed
            # x-retry-count must go to DLQ, not crash the callback forever.
            retries = parse_retry_count(properties)
            result = process(settings, body)
            MESSAGES.labels(result).inc()
            ch.basic_ack(method.delivery_tag)
        except PoisonMessage as exc:
            log.warning("poison message, sending to DLQ: %s", exc)
            publish_dlq(ch, body, f"poison: {exc}")
            MESSAGES.labels("poison").inc()
            ch.basic_ack(method.delivery_tag)
        except LookupError as exc:
            # Транзакции нет в БД — ретраить бессмысленно, это poison, не retriable.
            log.warning("unknown transfer, sending to DLQ: %s", exc)
            publish_dlq(ch, body, f"unknown-transfer: {exc}")
            MESSAGES.labels("poison").inc()
            ch.basic_ack(method.delivery_tag)
        except ProviderProtocolError as exc:
            # A malformed/unexpected provider answer will not improve on retry.
            log.error("provider protocol error, sending to DLQ: %s", exc)
            publish_dlq(ch, body, f"provider-protocol: {exc}")
            MESSAGES.labels("dlq").inc()
            ch.basic_ack(method.delivery_tag)
        except Exception:
            log.exception("failed to process message retries=%s", retries)
            if retries >= MAX_RETRIES:
                publish_dlq(ch, body, "max-retries")
                MESSAGES.labels("dlq").inc()
                ch.basic_ack(method.delivery_tag)
            else:
                MESSAGES.labels("retry").inc()
                # Backoff нужен: без него x5 ретраев пролетают за миллисекунды
                # и сообщение улетает в DLQ при коротком чихе провайдера
                # (проверено учением fail-mode 12s: без sleep — dlq, со sleep — COMPLETED).
                # Consumer однопоточный с prefetch=1 по дизайну (один трансфер за раз),
                # поэтому sleep здесь — осознанный компромисс, а не баг:
                # зависший провайдер виден через OldestPendingTooOld/DlqNonEmpty.
                delay = min(2**retries, 16)
                log.info("retry %s/%s in %ss", retries + 1, MAX_RETRIES, delay)
                time.sleep(delay)
                publish_confirmed(ch, QUEUE, body, headers={"x-retry-count": retries + 1})
                ch.basic_ack(method.delivery_tag)

    channel.basic_consume(queue=QUEUE, on_message_callback=on_message)
    log.info("consuming %s (dlq=%s, max_retries=%s)", QUEUE, DLQ, MAX_RETRIES)
    channel.start_consuming()


if __name__ == "__main__":
    main()
