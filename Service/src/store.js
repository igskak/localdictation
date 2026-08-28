// Every row this service is allowed to hold, and every question it asks of
// them.
//
// The table in `docs/PHASE_8.md` is the contract: a normalized address, a
// device hash, what was issued, a provider order id, and a rate-limit counter.
// Nothing content-derived appears here and nothing in this product could put it
// there — the app has no field to send it in. The one column that table does
// not name is `mailed_at`, and it is here so that pressing the button twice
// mails one key and a mailer that failed the first time can be retried.
//
// The key itself is deliberately **not** stored. Ed25519 is deterministic, so
// the same fields always produce the same token: keeping the fields is keeping
// the key, without keeping the key.

/// Wraps whatever `env.DB` is — a real D1 binding in production, a `node:sqlite`
/// database behind the same three methods in the tests.
export class Store {
  constructor(db) {
    this.db = db;
  }

  // MARK: - Licenses

  /// The strongest live entitlement on an address: lifetime, then an unexpired
  /// annual, then an unexpired trial. A refunded or charged-back license is
  /// dead and is skipped — an already-issued key keeps working, but this is
  /// where "no further issuance" is enforced.
  async strongestLicense(email, now) {
    const rows = await this.all(
      `SELECT * FROM licenses WHERE email = ? AND status = 'live'
         AND (expires_at IS NULL OR expires_at > ?)`,
      [email, now],
    );
    const rank = { lifetime: 3, annual: 2, trial: 1 };
    let best = null;
    for (const row of rows) {
      if (
        best === null ||
        rank[row.kind] > rank[best.kind] ||
        (rank[row.kind] === rank[best.kind] && (row.expires_at ?? Infinity) > (best.expires_at ?? Infinity))
      ) {
        best = row;
      }
    }
    return best;
  }

  async licenseByID(id) {
    return this.first(`SELECT * FROM licenses WHERE id = ?`, [id]);
  }

  async licenseByOrder(orderID) {
    return this.first(`SELECT * FROM licenses WHERE provider_order_id = ? LIMIT 1`, [orderID]);
  }

  /// Has this address ever had a trial? Asked of every trial ever issued, live
  /// or expired, because the answer "your fourteen days are over" is exactly
  /// what an expired one means.
  async hasHadTrial(email) {
    const row = await this.first(`SELECT id FROM licenses WHERE email = ? AND kind = 'trial' LIMIT 1`, [email]);
    return row != null;
  }

  /// The same question asked of the Mac. Kept in its own table rather than read
  /// off the device slots, because a slot can be released and a trial cannot be
  /// un-taken.
  async deviceHasHadTrial(device) {
    const row = await this.first(`SELECT device FROM trial_devices WHERE device = ?`, [device]);
    return row != null;
  }

  /// `device` is only used to remember that this Mac has had its trial. A
  /// license created by a purchase has no device yet — that is the whole reason
  /// activation is a second step.
  async createLicense({ id, email, kind, issuedAt, expiresAt, providerOrderID = null, device = null }) {
    await this.run(
      `INSERT INTO licenses (id, email, kind, status, issued_at, expires_at, provider_order_id, created_at)
       VALUES (?, ?, ?, 'live', ?, ?, ?, ?)`,
      [id, email, kind, issuedAt, expiresAt ?? null, providerOrderID, issuedAt],
    );
    if (kind === "trial" && device) {
      await this.run(`INSERT OR IGNORE INTO trial_devices (device, license_id, created_at) VALUES (?, ?, ?)`, [
        device,
        id,
        issuedAt,
      ]);
    }
    return this.licenseByID(id);
  }

  async extendLicense({ id, kind, expiresAt, providerOrderID }) {
    await this.run(
      `UPDATE licenses SET kind = ?, expires_at = ?, status = 'live', provider_order_id = COALESCE(?, provider_order_id)
       WHERE id = ?`,
      [kind, expiresAt ?? null, providerOrderID ?? null, id],
    );
    return this.licenseByID(id);
  }

  async killLicense(id) {
    await this.run(`UPDATE licenses SET status = 'dead' WHERE id = ?`, [id]);
  }

  // MARK: - Device slots

  async slot(licenseID, device) {
    return this.first(`SELECT * FROM device_slots WHERE license_id = ? AND device = ? AND released_at IS NULL`, [
      licenseID,
      device,
    ]);
  }

  /// The license a key belongs to, found the way the key itself describes it:
  /// the address it was issued to, the slot it named, and the key id inside it.
  /// A key whose slot has already been released still finds its license, which
  /// is what makes releasing twice a no-op rather than an error.
  async licenseForKey(email, keyID, device) {
    return this.first(
      `SELECT licenses.* FROM licenses
         JOIN device_slots ON device_slots.license_id = licenses.id
        WHERE licenses.email = ? AND device_slots.device = ? AND device_slots.key_id = ?
        LIMIT 1`,
      [email, device, keyID],
    );
  }

  async liveSlotCount(licenseID) {
    const row = await this.first(
      `SELECT COUNT(*) AS count FROM device_slots WHERE license_id = ? AND released_at IS NULL`,
      [licenseID],
    );
    return row?.count ?? 0;
  }

  async claimSlot({ licenseID, device, keyID, issuedAt, expiresAt }) {
    await this.run(
      `INSERT INTO device_slots (license_id, device, key_id, issued_at, expires_at, released_at, mailed_at)
       VALUES (?, ?, ?, ?, ?, NULL, NULL)
       ON CONFLICT (license_id, device) DO UPDATE SET
         key_id = excluded.key_id, issued_at = excluded.issued_at,
         expires_at = excluded.expires_at, released_at = NULL, mailed_at = NULL`,
      [licenseID, device, keyID, issuedAt, expiresAt ?? null],
    );
    return this.slot(licenseID, device);
  }

  /// A renewal moved the license's date; the slot keeps its key id and issue
  /// date and takes the new expiry, so the user gets a fresh key by mail rather
  /// than a stale one that stops working on the old date.
  async reissueSlot({ licenseID, device, expiresAt }) {
    await this.run(
      `UPDATE device_slots SET expires_at = ?, mailed_at = NULL WHERE license_id = ? AND device = ?`,
      [expiresAt ?? null, licenseID, device],
    );
    return this.slot(licenseID, device);
  }

  async markSlotMailed(licenseID, device, at) {
    await this.run(`UPDATE device_slots SET mailed_at = ? WHERE license_id = ? AND device = ?`, [at, licenseID, device]);
  }

  async releaseSlot(licenseID, device, at) {
    await this.run(
      `UPDATE device_slots SET released_at = ? WHERE license_id = ? AND device = ? AND released_at IS NULL`,
      [at, licenseID, device],
    );
  }

  // MARK: - Webhook idempotency

  /// True when this event has not been seen before. Every provider re-delivers,
  /// and a second delivery must not create a second license.
  async claimEvent(id, at) {
    const existing = await this.first(`SELECT id FROM webhook_events WHERE id = ?`, [id]);
    if (existing) return false;
    await this.run(`INSERT OR IGNORE INTO webhook_events (id, received_at) VALUES (?, ?)`, [id, at]);
    return true;
  }

  // MARK: - Rate limiting

  /// A fixed window, counted per bucket. Returns the count after this call.
  async bump(bucket, now, windowSeconds) {
    const start = now - (now % windowSeconds);
    const row = await this.first(`SELECT count, window_start FROM rate_counters WHERE bucket = ?`, [bucket]);
    if (!row || row.window_start !== start) {
      await this.run(
        `INSERT INTO rate_counters (bucket, count, window_start) VALUES (?, 1, ?)
         ON CONFLICT (bucket) DO UPDATE SET count = 1, window_start = excluded.window_start`,
        [bucket, start],
      );
      return 1;
    }
    const count = row.count + 1;
    await this.run(`UPDATE rate_counters SET count = ? WHERE bucket = ?`, [count, bucket]);
    return count;
  }

  /// Counters are the only place an IP appears, and they do not outlive a day.
  async forgetOldCounters(now) {
    await this.run(`DELETE FROM rate_counters WHERE window_start < ?`, [now - 86400]);
  }

  // MARK: - The three methods a D1 binding has

  async first(sql, params = []) {
    return this.db.prepare(sql).bind(...params).first();
  }

  async all(sql, params = []) {
    const result = await this.db.prepare(sql).bind(...params).all();
    return result.results ?? [];
  }

  async run(sql, params = []) {
    return this.db.prepare(sql).bind(...params).run();
  }
}
