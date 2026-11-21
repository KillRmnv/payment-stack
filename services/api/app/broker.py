import pika


def _params(settings):
    credentials = pika.PlainCredentials(settings.rabbitmq_user, settings.rabbitmq_password)
    return pika.ConnectionParameters(
        host=settings.rabbitmq_host, credentials=credentials, socket_timeout=3
    )


def ping(settings):
    try:
        connection = pika.BlockingConnection(_params(settings))
        connection.close()
        return True
    except Exception:  # noqa: BLE001 — any failure means "broker is down"
        return False
