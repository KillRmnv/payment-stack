import uuid
from types import SimpleNamespace

import pytest
from worker.messages import PoisonMessage, parse_message, parse_retry_count


def test_valid_message():
    value = uuid.uuid4()
    assert parse_message(f'{{"transfer_id": "{value}"}}'.encode()) == value


@pytest.mark.parametrize("body", [b"not json", b"{}", b'{"transfer_id": "nope"}', b"[]"])
def test_invalid_message(body):
    with pytest.raises(PoisonMessage):
        parse_message(body)


@pytest.mark.parametrize(
    "headers,expected",
    [
        ({}, 0),
        ({"x-retry-count": "3"}, 3),
        ({"x-retry-count": 4}, 4),
        ({"x-retry-count": b"5"}, 5),
    ],
)
def test_retry_count_valid(headers, expected):
    assert parse_retry_count(SimpleNamespace(headers=headers)) == expected


@pytest.mark.parametrize(
    "headers",
    [
        {"x-retry-count": "abc"},
        {"x-retry-count": ""},
        {"x-retry-count": None},
        {"x-retry-count": True},
        {"x-retry-count": -1},
        {"x-retry-count": "1.5"},
    ],
)
def test_retry_count_invalid_is_poison(headers):
    with pytest.raises(PoisonMessage):
        parse_retry_count(SimpleNamespace(headers=headers))


def test_retry_count_no_properties():
    assert parse_retry_count(None) == 0
