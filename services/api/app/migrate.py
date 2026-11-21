import hashlib
import logging
import time
from pathlib import Path

import psycopg

from .config import load_settings

log = logging.getLogger("migrate")

LOCK_ID = 420131
LOCK_WAIT_SECONDS = 30
LOCK_TIMEOUT = "30s"
STATEMENT_TIMEOUT = "10min"


def checksum(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def acquire_lock(conn):
    """Wait for the migration lock; never silently skip a concurrent deploy."""
    for _ in range(LOCK_WAIT_SECONDS):
        if conn.execute("SELECT pg_try_advisory_lock(%s)", (LOCK_ID,)).fetchone()[0]:
            return
        time.sleep(1)
    raise SystemExit(
        f"FATAL: another migrator holds advisory lock {LOCK_ID} for more than {LOCK_WAIT_SECONDS}s"
    )


def run(dsn, directory):
    with psycopg.connect(dsn, autocommit=True) as conn:
        # Do not block forever behind a long transaction, and do not let a
        # migration run away. Applies to DDL locks and the advisory lock wait.
        conn.execute(f"SET lock_timeout = '{LOCK_TIMEOUT}'")
        conn.execute(f"SET statement_timeout = '{STATEMENT_TIMEOUT}'")
        acquire_lock(conn)
        try:
            conn.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)")
            conn.execute("ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS checksum TEXT")
            applied = {
                row[0]: row[1]
                for row in conn.execute("SELECT version, checksum FROM schema_migrations")
            }
            for path in sorted(Path(directory).glob("*.sql")):
                digest = checksum(path)
                if path.name in applied:
                    stored = applied[path.name]
                    if stored is None:
                        conn.execute(
                            "UPDATE schema_migrations SET checksum = %s WHERE version = %s",
                            (digest, path.name),
                        )
                        log.info("recorded checksum for previously applied %s", path.name)
                    elif stored != digest:
                        raise SystemExit(
                            f"FATAL: migration {path.name} changed after it was applied"
                        )
                    continue
                with conn.transaction():
                    conn.execute(path.read_text())
                    conn.execute(
                        "INSERT INTO schema_migrations (version, checksum) VALUES (%s, %s)",
                        (path.name, digest),
                    )
                log.info("applied %s", path.name)
        finally:
            conn.execute("SELECT pg_advisory_unlock(%s)", (LOCK_ID,))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    run(load_settings().dsn, "migrations")
