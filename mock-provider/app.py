import datetime
import os
import uuid

from cryptography import x509
from starlette.applications import Starlette
from starlette.responses import JSONResponse, Response
from starlette.routing import Route

state = {"failing": False, "payouts": {}}


def api_key():
    return os.environ.get("PROVIDER_API_KEY", "")


async def health(request):
    return JSONResponse({"status": "ok", "failing": state["failing"]})


def cert_expiry_seconds():
    try:
        with open("/certs/cert.pem", "rb") as handle:
            cert = x509.load_pem_x509_certificate(handle.read())
        expiry = cert.not_valid_after_utc
        return int((expiry - datetime.datetime.now(datetime.UTC)).total_seconds())
    except Exception:  # noqa: BLE001 — unreadable/expired/missing cert is one metric failure
        return -1


async def metrics(request):
    body = (
        "# HELP provider_cert_expiry_seconds Seconds until mock provider TLS cert expiry (-1 = unreadable)\n"
        "# TYPE provider_cert_expiry_seconds gauge\n"
        f"provider_cert_expiry_seconds {cert_expiry_seconds()}\n"
        "# HELP provider_failing Whether fail-mode is enabled\n"
        "# TYPE provider_failing gauge\n"
        f"provider_failing {1 if state['failing'] else 0}\n"
    )
    return Response(body, media_type="text/plain; version=0.0.4")


async def create_payout(request):
    if not api_key() or request.headers.get("X-Api-Key") != api_key():
        return JSONResponse({"code": "UNAUTHORIZED"}, status_code=401)
    if state["failing"]:
        return JSONResponse({"code": "INTERNAL_ERROR"}, status_code=503)
    key = request.headers.get("Idempotency-Key") or uuid.uuid4().hex
    body = await request.json()
    payout = state["payouts"].setdefault(
        key,
        {
            "payout_id": f"po_{uuid.uuid4().hex[:16]}",
            "status": "COMPLETED",
            "reference": body.get("reference"),
        },
    )
    return JSONResponse(payout, status_code=201)


async def set_failing(request):
    # Учения/защита: без ключа любой кладет провайдера. Ключ = PROVIDER_API_KEY.
    if (
        request.headers.get("X-Api-Key") != api_key()
        and request.headers.get("X-Admin-Key") != api_key()
    ):
        return JSONResponse({"code": "UNAUTHORIZED"}, status_code=401)
    body = await request.json()
    state["failing"] = bool(body.get("enabled"))
    return JSONResponse({"failing": state["failing"]})


app = Starlette(
    routes=[
        Route("/health", health),
        Route("/metrics", metrics),
        Route("/payouts", create_payout, methods=["POST"]),
        Route("/admin/fail-mode", set_failing, methods=["POST"]),
    ]
)
