#!/bin/sh
set -e
# If a command is passed (e.g. migrator: python -m app.migrate), run it.
if [ $# -gt 0 ]; then
  exec "$@"
fi
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --no-access-log
