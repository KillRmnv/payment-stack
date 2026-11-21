import hashlib
import json
import re

KEY_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")


class InvalidIdempotencyKey(ValueError):
    pass


class IdempotencyConflict(Exception):
    pass


def normalize_key(raw):
    """Return a validated idempotency key or None when the header is absent.

    An empty header is invalid: a client that sends Idempotency-Key="" gets a
    400 instead of silently falling back to non-idempotent behaviour.
    """
    if raw is None:
        return None
    key = raw.strip()
    if not key or not KEY_RE.fullmatch(key):
        raise InvalidIdempotencyKey("Idempotency-Key must match [A-Za-z0-9._:-]{1,128}")
    return key


def request_hash(amount, currency, recipient):
    """Stable hash of the normalized request body.

    A repeated key with a different body is a client bug and must not return the
    old transfer: the API responds 409 instead.
    """
    payload = {
        "amount": str(amount),
        "currency": currency,
        "recipient": recipient,
    }
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()
