#!/bin/sh
set -e
if [ ! -f /certs/cert.pem ]; then
  python3 -c "
from cryptography import x509
from cryptography.x509.oid import NameOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
import datetime
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
subject = issuer = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'mock-provider')])
cert = (x509.CertificateBuilder().subject_name(subject).issuer_name(issuer)
  .public_key(key.public_key()).serial_number(x509.random_serial_number())
  .not_valid_before(datetime.datetime.utcnow()).not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=365))
  .add_extension(x509.SubjectAlternativeName([x509.DNSName('mock-provider')]), critical=False)
  .sign(key, hashes.SHA256()))
open('/certs/key.pem','wb').write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.TraditionalOpenSSL, serialization.NoEncryption()))
open('/certs/cert.pem','wb').write(cert.public_bytes(serialization.Encoding.PEM))
"
fi
exec uvicorn app:app --host 0.0.0.0 --port 9443 --ssl-keyfile /certs/key.pem --ssl-certfile /certs/cert.pem --no-access-log
