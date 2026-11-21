def format_minor(minor):
    """Format integer minor units without float rounding (e.g. 10050 -> 100.50)."""
    minor = int(minor)
    sign = "-" if minor < 0 else ""
    minor = abs(minor)
    return f"{sign}{minor // 100}.{minor % 100:02d}"
