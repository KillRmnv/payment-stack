#!/bin/sh
set -e

# Renew the self-signed provider certificate when it is missing, unreadable or
# expires within 30 days. The volume is shared with the worker, so a restart
# (deploy/rollout) is enough to make the new CA visible.
NEEDS_RENEW=0
if [ ! -f /certs/cert.pem ] || [ ! -f /certs/key.pem ]; then
  NEEDS_RENEW=1
fi
if [ "$NEEDS_RENEW" = 0 ]; then
  python3 -c "
from cryptography import x509
import datetime
import sys
try:
    cert = x509.load_pem_x509_certificate(open('/certs/cert.pem', 'rb').read())
    left = (cert.not_valid_after_utc - datetime.datetime.now(datetime.UTC)).total_seconds()
    sys.exit(0 if left > 30 * 24 * 3600 else 1)
except Exception:
    sys.exit(1)
" || NEEDS_RENEW=1
fi

if [ "$NEEDS_RENEW" = 1 ]; then
  echo "generating mock-provider TLS certificate (expires in 365 days)" >&2
  python3 -c "
import datetime
import os
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import NameOID

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'mock-provider')])
now = datetime.datetime.now(datetime.UTC).replace(tzinfo=None)
cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer)
  .public_key(key.public_key()).serial_number(x509.random_serial_number())
  .not_valid_before(now).not_valid_after(now + datetime.timedelta(days=365))
  .add_extension(x509.SubjectAlternativeName([x509.DNSName('mock-provider')]), critical=False)
  .sign(key, hashes.SHA256()))
open('/certs/key.pem', 'wb').write(key.private_bytes(
  serialization.Encoding.PEM,
  serialization.PrivateFormat.TraditionalOpenSSL,
  serialization.NoEncryption(),
))
open('/certs/cert.pem', 'wb').write(cert.public_bytes(serialization.Encoding.PEM))
os.chmod('/certs/key.pem', 0o600)
os.chmod('/certs/cert.pem', 0o644)
"
fi

exec uvicorn app:app --host 0.0.0.0 --port 9443 --ssl-keyfile /certs/key.pem --ssl-certfile /certs/cert.pem --no-access-log
