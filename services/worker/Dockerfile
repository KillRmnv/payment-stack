# syntax=docker/dockerfile:1
ARG PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df

FROM ${PYTHON_IMAGE} AS builder
WORKDIR /app
COPY services/worker/requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM ${PYTHON_IMAGE} AS runtime
RUN useradd -u 10000 -m appuser
WORKDIR /app
COPY --from=builder /root/.local /home/appuser/.local
COPY --chown=appuser:appuser services/worker/worker ./worker
ENV PATH=/home/appuser/.local/bin:$PATH
USER appuser
EXPOSE 8001
CMD ["python", "-m", "worker.consumer"]
