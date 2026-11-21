import json
import uuid


class PoisonMessage(Exception):
    pass


def parse_message(body):
    try:
        payload = json.loads(body)
        return uuid.UUID(payload["transfer_id"])
    except (ValueError, KeyError, TypeError) as exc:
        raise PoisonMessage(str(exc)) from exc


def parse_retry_count(properties):
    """Return a safe retry counter.

    Headers are untrusted input: a non-numeric x-retry-count used to raise
    ValueError outside the consumer's try block, leaving the message unacked and
    redelivered forever (poison loop). Treat malformed values as poison instead.
    """
    headers = getattr(properties, "headers", None) or {}
    raw = headers.get("x-retry-count", 0)
    if isinstance(raw, bool):
        raise PoisonMessage(f"invalid x-retry-count={raw!r}")
    try:
        retries = int(raw)
    except (TypeError, ValueError) as exc:
        raise PoisonMessage(f"invalid x-retry-count={raw!r}") from exc
    if retries < 0:
        raise PoisonMessage(f"negative x-retry-count={retries}")
    return retries
