import logging

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
DLQ_DEPTH = Gauge("worker_dlq_depth", "DLQ depth (last publish count)")


def process(settings, body):
    transfer_id = parse_message(body)  # raises PoisonMessage
    with psycopg.connect(settings.dsn) as conn:
        row = conn.execute(
            "SELECT amount_minor, currency, recipient, status FROM transfers WHERE id = %s FOR UPDATE", (transfer_id,)
        ).fetchone()
        if row is None:
            raise LookupError(f"transfer {transfer_id} does not exist")
        amount_minor, currency, recipient, status = row
        if status != "PENDING":
            return "duplicate"
        payout = send_payout(settings, transfer_id, f"{amount_minor / 100:.2f}", currency, recipient)
        conn.execute(
            "UPDATE transfers SET status = %s, provider_reference = %s, updated_at = now() WHERE id = %s",
            (payout["status"], payout["payout_id"], transfer_id),
        )
    log.info("transfer %s is %s", transfer_id, payout["status"])
    return "processed"


def publish_dlq(channel, body, reason):
    channel.queue_declare(queue=DLQ, durable=True)
    channel.basic_publish(exchange="", routing_key=DLQ, body=body,
                          properties=pika.BasicProperties(delivery_mode=2, headers={"x-death-reason": reason}))


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
        except Exception:
            log.exception("failed to process message retries=%s", retries)
            if retries >= MAX_RETRIES:
                publish_dlq(ch, body, "max-retries")
                MESSAGES.labels("dlq").inc()
                ch.basic_ack(method.delivery_tag)
            else:
                MESSAGES.labels("retry").inc()
                ch.basic_publish(exchange="", routing_key=QUEUE, body=body,
                                 properties=pika.BasicProperties(delivery_mode=2, headers={"x-retry-count": retries + 1}))
                ch.basic_ack(method.delivery_tag)

    channel.basic_consume(queue=QUEUE, on_message_callback=on_message)
    log.info("consuming %s (dlq=%s, max_retries=%s)", QUEUE, DLQ, MAX_RETRIES)
    channel.start_consuming()


if __name__ == "__main__":
    main()
