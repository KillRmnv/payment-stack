from worker.money import format_minor


def test_format_minor_is_exact():
    assert format_minor(10050) == "100.50"
    assert format_minor(1) == "0.01"
    assert format_minor(999999999999) == "9999999999.99"
    assert format_minor(0) == "0.00"
