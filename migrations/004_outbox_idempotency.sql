ALTER TABLE transfers ADD COLUMN idempotency_key TEXT;
ALTER TABLE transfers ADD COLUMN request_hash TEXT;
ALTER TABLE transfers
    ADD CONSTRAINT transfers_idempotency_key_key UNIQUE (idempotency_key);

-- The starter API had dual-write: INSERT committed before RabbitMQ publish.
-- transfer_outbox makes the message part of the same transaction.
CREATE TABLE transfer_outbox (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    transfer_id UUID NOT NULL UNIQUE REFERENCES transfers(id),
    payload JSONB NOT NULL,
    status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING', 'SENT')),
    attempts INTEGER NOT NULL DEFAULT 0,
    next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at TIMESTAMPTZ
);

CREATE INDEX transfer_outbox_due_idx
    ON transfer_outbox (status, next_attempt_at);

-- Backfill transfers that were already PENDING before the outbox existed.
-- Existing DLQ/retry history stays in RabbitMQ; the worker is idempotent.
INSERT INTO transfer_outbox (transfer_id, payload)
SELECT t.id, jsonb_build_object('transfer_id', t.id)
FROM transfers t
LEFT JOIN transfer_outbox o ON o.transfer_id = t.id
WHERE t.status = 'PENDING' AND o.id IS NULL
ON CONFLICT (transfer_id) DO NOTHING;
