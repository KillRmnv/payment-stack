import pytest
from worker.provider import ProviderProtocolError, parse_payout


def test_parse_payout_completed():
    assert parse_payout({"payout_id": "po_1", "status": "COMPLETED"}) == {
        "payout_id": "po_1",
        "status": "COMPLETED",
    }


def test_parse_payout_failed():
    assert parse_payout({"payout_id": " po_2 ", "status": "FAILED"})["payout_id"] == "po_2"


@pytest.mark.parametrize(
    "payload",
    [
        None,
        [],
        {},
        {"status": "COMPLETED"},
        {"payout_id": "", "status": "COMPLETED"},
        {"payout_id": "po_1"},
        {"payout_id": "po_1", "status": "PENDING"},
        {"payout_id": "po_1", "status": "SOMETHING_ELSE"},
        {"payout_id": 123, "status": "COMPLETED"},
    ],
)
def test_parse_payout_invalid(payload):
    with pytest.raises(ProviderProtocolError):
        parse_payout(payload)
