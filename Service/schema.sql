-- The whole of what this service stores.
--
-- `docs/PHASE_8.md` lists it: a normalized address, a device hash, what was
-- issued, a provider order id, and a rate-limit counter. Nothing derived from
-- anything a user dictated appears here, and nothing in the product could put
-- it here — the app's request has two fields.
--
-- The device hash cannot be turned back into a serial number, and the
-- `install_id` a product event would carry is generated separately so the two
-- cannot be joined.

CREATE TABLE IF NOT EXISTS licenses (
    id                TEXT PRIMARY KEY,       -- uuid, also the key id of nothing: keys have their own
    email             TEXT NOT NULL,          -- normalized: trimmed, lowercased
    kind              TEXT NOT NULL CHECK (kind IN ('trial', 'annual', 'lifetime')),
    status            TEXT NOT NULL DEFAULT 'live' CHECK (status IN ('live', 'dead')),
    issued_at         INTEGER NOT NULL,       -- whole seconds since the epoch
    expires_at        INTEGER,                -- NULL for lifetime
    provider_order_id TEXT,                   -- for reconciling a payment
    created_at        INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS licenses_by_email ON licenses (email);

-- One row per Mac a license covers. Two live rows is the limit, and releasing
-- one is what lets a third Mac in.
--
-- The key is not stored. Ed25519 is deterministic, so these five fields
-- reproduce the exact token that was issued, byte for byte.
CREATE TABLE IF NOT EXISTS device_slots (
    license_id  TEXT NOT NULL REFERENCES licenses (id),
    device      TEXT NOT NULL,                -- 32 lowercase hex, salted hash of the hardware UUID
    key_id      TEXT NOT NULL,                -- the uuid inside the key's payload
    issued_at   INTEGER NOT NULL,
    expires_at  INTEGER,
    released_at INTEGER,                      -- non-NULL once the slot is freed
    mailed_at   INTEGER,                      -- NULL until the key has actually been delivered
    PRIMARY KEY (license_id, device)
);

-- A trial is once per address and once per Mac. A slot can be released; a trial
-- cannot be un-taken, so it is remembered here rather than inferred from slots.
CREATE TABLE IF NOT EXISTS trial_devices (
    device     TEXT PRIMARY KEY,
    license_id TEXT NOT NULL,
    created_at INTEGER NOT NULL
);

-- Every provider re-delivers. Idempotency on their event id is what keeps a
-- redelivery from creating a second license.
CREATE TABLE IF NOT EXISTS webhook_events (
    id          TEXT PRIMARY KEY,
    received_at INTEGER NOT NULL
);

-- The only place an IP address appears, as a counter, for a day.
CREATE TABLE IF NOT EXISTS rate_counters (
    bucket       TEXT PRIMARY KEY,
    count        INTEGER NOT NULL,
    window_start INTEGER NOT NULL
);
