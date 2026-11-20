# syntax=docker/dockerfile:1
ARG PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:935c3c5b12357a7e10caa9c1e6ca5692344d97cf229832ef584be2cec9fc03df

FROM ${PYTHON_IMAGE} AS builder
WORKDIR /app
COPY services/api/requirements.txt .
RUN pip install --no-cache-dir --user -r requirements.txt

FROM ${PYTHON_IMAGE} AS runtime
RUN useradd -u 10000 -m appuser
WORKDIR /app
COPY --from=builder /root/.local /home/appuser/.local
COPY --chown=appuser:appuser services/api/app ./app
COPY --chown=appuser:appuser migrations ./migrations
COPY --chown=appuser:appuser services/api/entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh
ENV PATH=/home/appuser/.local/bin:$PATH
USER appuser
EXPOSE 8000
ENTRYPOINT ["./entrypoint.sh"]
