-- Widens `product_events.event` to the three file transcription events.
--
-- Same rebuild as `001-setup-funnel-events.sql`, and for the same reason:
-- SQLite cannot alter a `CHECK`. Safe to run more than once and safe to run
-- before the app that sends the new events.
--
--     npx wrangler d1 execute localdictation-licenses --remote \
--       --file migrations/002-file-transcription-events.sql
--
-- Run it *before* deploying the worker that accepts the new names. A worker
-- that accepts an event this table still refuses answers 202 to the app and
-- loses the row, which is the one failure here that is silent.

CREATE TABLE IF NOT EXISTS product_events_rebuilt (
    id             INTEGER PRIMARY KEY AUTOINCREMENT,
    install_id     TEXT NOT NULL,
    event          TEXT NOT NULL CHECK (event IN (
                       'installed',
                       'model_download_started',
                       'model_ready',
                       'model_failed',
                       'dictation_blocked_by_model',
                       'microphone_denied',
                       'trial_started',
                       'activation_requested',
                       'paywall_shown',
                       'file_transcription_started',
                       'file_transcription_completed',
                       'file_transcription_failed'
                   )),
    qualifier      TEXT,
    app_version    TEXT NOT NULL,
    system_version TEXT NOT NULL,
    received_at    INTEGER NOT NULL
);

INSERT INTO product_events_rebuilt (id, install_id, event, qualifier, app_version, system_version, received_at)
SELECT id, install_id, event, qualifier, app_version, system_version, received_at FROM product_events;

DROP TABLE product_events;

ALTER TABLE product_events_rebuilt RENAME TO product_events;

CREATE INDEX IF NOT EXISTS product_events_by_install ON product_events (install_id);
CREATE INDEX IF NOT EXISTS product_events_by_age ON product_events (received_at);
