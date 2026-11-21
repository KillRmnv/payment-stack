from worker.outbox import backoff_seconds


def test_backoff_grows_and_caps():
    assert [backoff_seconds(n) for n in range(8)] == [1, 2, 4, 8, 16, 32, 60, 60]


def test_backoff_negative_is_safe():
    assert backoff_seconds(-5) == 1
