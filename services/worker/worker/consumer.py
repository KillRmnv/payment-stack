import logging
import time

import pika
import psycopg
from prometheus_client import Counter, Gauge, start_http_server

from .config import load_settings
from .messages import PoisonMessage, parse_message
from .provider import send_payout

log = logging.getLogger("worker")
QUEUE = "transfers"
DLQ = "transfers.dlq"
MAX_RETRIES = 5
MESSAGES = Counter("worker_messages_total", "Processed messages", ["result"])
DLQ_DEPTH = Gauge("worker_dlq_depth", "DLQ depth (total published to DLQ)")


def process(settings, body):
    transfer_id = parse_message(body)  # raises PoisonMessage
    request_id = str(transfer_id)  # Idempotency-Key == transfer_id, сквозной request_id
    with psycopg.connect(settings.dsn) as conn:
        row = conn.execute(
            "SELECT amount_minor, currency, recipient, status FROM transfers WHERE id = %s FOR UPDATE", (transfer_id,)
        ).fetchone()
        if row is None:
            raise LookupError(f"transfer {transfer_id} does not exist")
        amount_minor, currency, recipient, status = row
        if status != "PENDING":
            log.info("transfer_id=%s request_id=%s duplicate status=%s", transfer_id, request_id, status)
            return "duplicate"
        payout = send_payout(settings, transfer_id, f"{amount_minor / 100:.2f}", currency, recipient)
        conn.execute(
            "UPDATE transfers SET status = %s, provider_reference = %s, updated_at = now() WHERE id = %s",
            (payout["status"], payout["payout_id"], transfer_id),
        )
    log.info("transfer_id=%s request_id=%s processed status=%s", transfer_id, request_id, payout["status"])
    return "processed"


def publish_dlq(channel, body, reason):
    channel.queue_declare(queue=DLQ, durable=True)
    channel.basic_publish(exchange="", routing_key=DLQ, body=body,
                          properties=pika.BasicProperties(delivery_mode=2, headers={"x-death-reason": reason}))
    DLQ_DEPTH.inc()


def main():
    settings = load_settings()
    logging.basicConfig(level=settings.log_level, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    start_http_server(8001)
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    connection = pika.BlockingConnection(pika.ConnectionParameters(host=settings.rabbitmq_host, credentials=credentials))
    channel = connection.channel()
    channel.queue_declare(queue=QUEUE, durable=True)
    channel.queue_declare(queue=DLQ, durable=True)
    channel.basic_qos(prefetch_count=1)

    def on_message(ch, method, properties, body):
        headers = (properties.headers or {}) if properties else {}
        retries = int(headers.get("x-retry-count", 0))
        try:
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
        except Exception:
            log.exception("failed to process message retries=%s", retries)
            if retries >= MAX_RETRIES:
                publish_dlq(ch, body, "max-retries")
                MESSAGES.labels("dlq").inc()
                ch.basic_ack(method.delivery_tag)
            else:
                MESSAGES.labels("retry").inc()
                # Dampen hot-loop: линейный backoff перед републикацией.
                time.sleep(min(retries + 1, 5))
                ch.basic_publish(exchange="", routing_key=QUEUE, body=body,
                                 properties=pika.BasicProperties(delivery_mode=2, headers={"x-retry-count": retries + 1}))
                ch.basic_ack(method.delivery_tag)

    channel.basic_consume(queue=QUEUE, on_message_callback=on_message)
    log.info("consuming %s (dlq=%s, max_retries=%s)", QUEUE, DLQ, MAX_RETRIES)
    channel.start_consuming()


if __name__ == "__main__":
    main()
