-- Widens `product_events.event` to the six setup events.
--
-- `schema.sql` is written for a database that does not exist yet: every table
-- in it is `CREATE TABLE IF NOT EXISTS`, so running it again against the live
-- D1 changes nothing. SQLite has no `ALTER TABLE ... DROP CONSTRAINT` either,
-- so widening a `CHECK` is a rebuild, and this file is that rebuild.
--
-- It is safe to run more than once, and safe to run before the version of the
-- app that sends the new events: what it changes is which names are accepted,
-- not what is stored. Rows are copied rather than dropped, although they are
-- ninety-day rows and nothing would break if they were not.
--
--     npx wrangler d1 execute localdictation-licenses --remote \
--       --file migrations/001-setup-funnel-events.sql
--
-- Run it *before* deploying the worker that accepts the new names. A worker
-- that accepts an event this table still refuses answers 202 to the app and
-- loses the row, which is the one failure here that is silent.
--
-- No `PRAGMA foreign_keys` around the rebuild, although that is the usual
-- ceremony for one: D1 accepts only a few pragmas, and this table neither has
-- a foreign key nor is the target of one. The two that exist in `schema.sql`
-- both point at `licenses`, which this file does not touch.

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
                       'paywall_shown'
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
