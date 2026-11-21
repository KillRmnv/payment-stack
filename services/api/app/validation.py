import re
from decimal import Decimal

AMOUNT = re.compile(r"^[0-9]+\.[0-9]{2}$")
CURRENCY = re.compile(r"^[A-Z]{3}$")
# 10 billion currency units. Above this, BIGINT/fake-provider amounts and
# float-based display become unsafe; reject early with 400 instead of a DB 500.
MAX_AMOUNT_MINOR = 10**12


class InvalidTransfer(Exception):
    pass


def parse_transfer(body):
    if not isinstance(body, dict):
        raise InvalidTransfer("body must be an object")
    amount = body.get("amount")
    currency = body.get("currency")
    recipient = body.get("recipient")
    if not isinstance(amount, str) or not AMOUNT.match(amount) or Decimal(amount) <= 0:
        raise InvalidTransfer("amount must look like 100.00")
    minor = to_minor(Decimal(amount))
    if minor > MAX_AMOUNT_MINOR:
        raise InvalidTransfer("amount exceeds the maximum allowed value")
    if not isinstance(currency, str) or not CURRENCY.match(currency):
        raise InvalidTransfer("currency must be a three letter code")
    if not isinstance(recipient, str) or not recipient.strip():
        raise InvalidTransfer("recipient is required")
    return Decimal(amount), currency, recipient.strip()


def to_minor(amount):
    return int(amount * 100)


def format_minor(minor):
    """Format integer minor units without float rounding (e.g. 10050 -> 100.50)."""
    minor = int(minor)
    sign = "-" if minor < 0 else ""
    minor = abs(minor)
    return f"{sign}{minor // 100}.{minor % 100:02d}"
