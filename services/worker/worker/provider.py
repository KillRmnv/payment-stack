import requests

CA_BUNDLE_ENV = "PROVIDER_CA_BUNDLE"


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
    return response.json()
