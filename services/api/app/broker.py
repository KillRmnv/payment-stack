import json

import pika

QUEUE = "transfers"


def _params(settings):
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    return pika.ConnectionParameters(
        host=settings.rabbitmq_host, credentials=credentials, socket_timeout=3
    )


def publish(settings, message):
    connection = pika.BlockingConnection(_params(settings))
    try:
        channel = connection.channel()
        channel.queue_declare(queue=QUEUE, durable=True)
        channel.basic_publish(
            exchange="",
            routing_key=QUEUE,
            body=json.dumps(message),
            properties=pika.BasicProperties(delivery_mode=2),
        )
    finally:
        connection.close()


def ping(settings):
    try:
        connection = pika.BlockingConnection(_params(settings))
        connection.close()
        return True
    except Exception:  # noqa: BLE001 — any failure means "broker is down"
        return False
