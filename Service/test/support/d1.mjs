// A D1 binding, for the length of a test.
//
// `node:sqlite` behind the three methods a Workers D1 binding has, running the
// real `schema.sql`. A hand-written fake would be a fake of what this service
// believes SQLite does; this way the constraints, the `ON CONFLICT` clauses and
// the `COUNT(*)` are the ones that will run in production.

import { DatabaseSync } from "node:sqlite";
import { readFileSync } from "node:fs";

const SCHEMA = readFileSync(new URL("../../schema.sql", import.meta.url), "utf8");

export function makeTestDatabase() {
  const db = new DatabaseSync(":memory:");
  db.exec(SCHEMA);

  return {
    prepare(sql) {
      const statement = db.prepare(sql);
      let parameters = [];
      const api = {
        bind(...values) {
          parameters = values.map((value) => (value === undefined ? null : value));
          return api;
        },
        async first(column) {
          const row = statement.get(...parameters) ?? null;
          if (row == null) return null;
          return column === undefined ? { ...row } : row[column];
        },
        async all() {
          return { success: true, results: statement.all(...parameters).map((row) => ({ ...row })) };
        },
        async run() {
          const info = statement.run(...parameters);
          return { success: true, meta: { changes: Number(info.changes ?? 0) } };
        },
      };
      return api;
    },
    close() {
      db.close();
    },
  };
}
