import pytest
from worker.consumer import publish_confirmed


class FakeChannel:
    def __init__(self, confirmed):
        self.confirmed = confirmed
        self.calls = []

    def basic_publish(self, **kwargs):
        self.calls.append(kwargs)
        return self.confirmed


def test_publish_confirmed_success():
    channel = FakeChannel(True)
    publish_confirmed(channel, "transfers", b"{}", headers={"x-retry-count": 1})
    assert channel.calls[0]["routing_key"] == "transfers"
    assert channel.calls[0]["properties"].headers == {"x-retry-count": 1}


def test_publish_confirmed_failure_raises():
    with pytest.raises(RuntimeError):
        publish_confirmed(FakeChannel(False), "transfers", b"{}")
