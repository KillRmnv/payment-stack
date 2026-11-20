# syntax=docker/dockerfile:1
ARG PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df

FROM ${PYTHON_IMAGE} AS builder
WORKDIR /app
COPY mock-provider/requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt && pip install --no-cache-dir --user cryptography==42.0.5

FROM ${PYTHON_IMAGE} AS runtime
RUN useradd -u 10000 -m appuser && mkdir -p /certs && chown appuser:appuser /certs
WORKDIR /app
COPY --from=builder /root/.local /home/appuser/.local
COPY --chown=appuser:appuser mock-provider/app.py mock-provider/entrypoint.sh ./
RUN chmod +x ./entrypoint.sh
ENV PATH=/home/appuser/.local/bin:$PATH
USER appuser
EXPOSE 9443
ENTRYPOINT ["./entrypoint.sh"]
