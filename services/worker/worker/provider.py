import requests

CA_BUNDLE_ENV = "PROVIDER_CA_BUNDLE"
TERMINAL_STATUSES = frozenset({"COMPLETED", "FAILED"})


class ProviderProtocolError(Exception):
    """Provider returned a response that cannot be safely persisted."""


def parse_payout(payload):
    if not isinstance(payload, dict):
        raise ProviderProtocolError("payout response must be an object")
    payout_id = payload.get("payout_id")
    status = payload.get("status")
    if not isinstance(payout_id, str) or not payout_id.strip():
        raise ProviderProtocolError("payout response is missing payout_id")
    if status not in TERMINAL_STATUSES:
        raise ProviderProtocolError(f"unexpected payout status: {status!r}")
    return {"payout_id": payout_id.strip(), "status": status}


def send_payout(settings, transfer_id, amount, currency, recipient):
    response = requests.post(
        f"{settings.provider_url}/payouts",
        json={
            "reference": str(transfer_id),
            "amount": str(amount),
            "currency": currency,
            "recipient": recipient,
        },
        headers={"X-Api-Key": settings.provider_api_key, "Idempotency-Key": str(transfer_id)},
        timeout=(3, 10),
        verify=settings.provider_ca_bundle,
    )
    response.raise_for_status()
    try:
        payload = response.json()
    except ValueError as exc:
        raise ProviderProtocolError("payout response is not valid JSON") from exc
    return parse_payout(payload)
