from decimal import Decimal

import pytest
from app.idempotency import InvalidIdempotencyKey, normalize_key, request_hash


def test_missing_key_is_none():
    assert normalize_key(None) is None


@pytest.mark.parametrize("key", ["k-1", "abc.DEF_123:456", "a" * 128])
def test_valid_key(key):
    assert normalize_key(f"  {key}  ") == key


@pytest.mark.parametrize("key", ["", "   ", "a" * 129, "bad key", "ключ", "x/y"])
def test_invalid_key(key):
    with pytest.raises(InvalidIdempotencyKey):
        normalize_key(key)


def test_request_hash_is_stable_and_normalized():
    assert request_hash(Decimal("100.00"), "RUB", "TH123") == request_hash(
        Decimal("100.00"), "RUB", "TH123"
    )


def test_request_hash_changes_with_body():
    base = request_hash(Decimal("100.00"), "RUB", "TH123")
    assert base != request_hash(Decimal("100.01"), "RUB", "TH123")
    assert base != request_hash(Decimal("100.00"), "USD", "TH123")
    assert base != request_hash(Decimal("100.00"), "RUB", "TH124")
