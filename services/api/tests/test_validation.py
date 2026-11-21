from decimal import Decimal

import pytest
from app.validation import (
    MAX_AMOUNT_MINOR,
    InvalidTransfer,
    format_minor,
    parse_transfer,
    to_minor,
)


def test_valid_transfer():
    assert parse_transfer({"amount": "100.50", "currency": "RUB", "recipient": " TH1 "}) == (
        Decimal("100.50"),
        "RUB",
        "TH1",
    )


@pytest.mark.parametrize(
    "body",
    [
        {"amount": "1", "currency": "RUB", "recipient": "x"},
        {"amount": "0.00", "currency": "RUB", "recipient": "x"},
        {"amount": "1.00", "currency": "rub", "recipient": "x"},
        {"amount": "1.00", "currency": "RUB", "recipient": " "},
        {"amount": 1, "currency": "RUB", "recipient": "x"},
        [],
    ],
)
def test_invalid_transfer(body):
    with pytest.raises(InvalidTransfer):
        parse_transfer(body)


def test_to_minor():
    assert to_minor(Decimal("100.50")) == 10050


def test_format_minor_is_exact():
    assert format_minor(10050) == "100.50"
    assert format_minor(1) == "0.01"
    assert format_minor(999999999999) == "9999999999.99"


def test_amount_over_limit_is_rejected():
    over = f"{MAX_AMOUNT_MINOR // 100 + 1}.00"
    with pytest.raises(InvalidTransfer):
        parse_transfer({"amount": over, "currency": "RUB", "recipient": "x"})


def test_amount_at_limit_is_allowed():
    at_limit = f"{MAX_AMOUNT_MINOR // 100}.00"
    assert parse_transfer({"amount": at_limit, "currency": "RUB", "recipient": "x"})[0] == Decimal(
        at_limit
    )
