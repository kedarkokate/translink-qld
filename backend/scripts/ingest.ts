/**
 * GTFS ingest — downloads the SEQ GTFS zip and bulk-loads it into D1.
 *
 * Usage:
 *   npm run seed:local     # writes to local D1 (.wrangler dir)
 *   npm run seed:remote    # writes to your live D1 via Cloudflare API
 *
 * The remote path needs three env vars (put them in backend/.env):
 *   CF_ACCOUNT_ID=...
 *   CF_API_TOKEN=...        (token with D1:Edit on the account)
 *   CF_D1_DATABASE_ID=...   (same UUID as wrangler.toml database_id)
 */
import { createWriteStream, createReadStream, readdirSync } from "node:fs";
import { mkdir, rm, readFile } from "node:fs/promises";
import { pipeline } from "node:stream/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { DatabaseSync, StatementSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import unzipper from "unzipper";
import { parse } from "csv-parse";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const GTFS_URL =
  process.env.TRANSLINK_GTFS_URL ?? "https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip";
const BATCH = 5000;

const mode = process.argv.includes("--remote") ? "remote" : "local";

async function main() {
  const work = path.join(tmpdir(), `translink-gtfs-${Date.now()}`);
  await mkdir(work, { recursive: true });
  const zipPath = path.join(work, "gtfs.zip");
  console.log(`↓ downloading ${GTFS_URL} → ${zipPath}`);
  await download(GTFS_URL, zipPath);

  const extractDir = path.join(work, "extracted");
  await mkdir(extractDir, { recursive: true });
  console.log(`⤓ extracting…`);
  await pipeline(createReadStream(zipPath), unzipper.Extract({ path: extractDir }));

  const exec = mode === "local" ? execLocal : execRemote;
  console.log(`→ writing to ${mode} D1`);

  await ingestTable(extractDir, "agency.txt", "agencies", [
    ["agency_id", s => s], ["agency_name", s => s],
    ["agency_url", s => s ?? null], ["agency_timezone", s => s, "agency_tz"],
  ], exec);

  await ingestTable(extractDir, "stops.txt", "stops", [
    ["stop_id", s => s], ["stop_code", s => s ?? null], ["stop_name", s => s],
    ["stop_lat", s => Number(s)], ["stop_lon", s => Number(s)],
    ["location_type", s => Number(s ?? 0)],
    ["parent_station", s => s ?? null], ["platform_code", s => s ?? null],
  ], exec);

  await ingestTable(extractDir, "routes.txt", "routes", [
    ["route_id", s => s], ["agency_id", s => s ?? null],
    ["route_short_name", s => s ?? null], ["route_long_name", s => s ?? null],
    ["route_type", s => Number(s)],
    ["route_color", s => s ?? null], ["route_text_color", s => s ?? null],
  ], exec);

  await ingestTable(extractDir, "calendar.txt", "calendar", [
    ["service_id", s => s],
    ["monday", s => Number(s)], ["tuesday", s => Number(s)],
    ["wednesday", s => Number(s)], ["thursday", s => Number(s)],
    ["friday", s => Number(s)], ["saturday", s => Number(s)],
    ["sunday", s => Number(s)],
    ["start_date", s => s], ["end_date", s => s],
  ], exec);

  await ingestTable(extractDir, "calendar_dates.txt", "calendar_dates", [
    ["service_id", s => s], ["date", s => s],
    ["exception_type", s => Number(s)],
  ], exec);

  await ingestTable(extractDir, "trips.txt", "trips", [
    ["trip_id", s => s], ["route_id", s => s], ["service_id", s => s],
    ["trip_headsign", s => s ?? null],
    ["direction_id", s => s == null || s === "" ? null : Number(s)],
    ["shape_id", s => s ?? null], ["block_id", s => s ?? null],
  ], exec);

  await ingestTable(extractDir, "stop_times.txt", "stop_times", [
    ["trip_id", s => s],
    ["arrival_time", s => s], ["departure_time", s => s],
    ["stop_id", s => s], ["stop_sequence", s => Number(s)],
    ["pickup_type", s => Number(s ?? 0)],
    ["drop_off_type", s => Number(s ?? 0)],
  ], exec);

  console.log(`→ deriving route_types per stop`);
  await exec([
    { sql: `DROP TABLE IF EXISTS stop_modes_tmp`, params: [] },
    { sql: `CREATE TEMP TABLE stop_modes_tmp AS
            SELECT st.stop_id, GROUP_CONCAT(DISTINCT r.route_type) AS rts
            FROM stop_times st
            JOIN trips t ON t.trip_id = st.trip_id
            JOIN routes r ON r.route_id = t.route_id
            GROUP BY st.stop_id`, params: [] },
    { sql: `UPDATE stops SET route_types = (
              SELECT rts FROM stop_modes_tmp WHERE stop_id = stops.stop_id
            )`, params: [] },
    { sql: `DROP TABLE stop_modes_tmp`, params: [] },
  ]);

  await exec([{
    sql: `INSERT INTO feed_meta(key, value, updated_at)
          VALUES('last_ingest', ?1, ?2)
          ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
    params: [new Date().toISOString(), Math.floor(Date.now() / 1000)],
  }]);

  console.log("✓ ingest complete, cleaning up");
  await rm(work, { recursive: true, force: true });
}

type ColSpec = readonly [src: string, transform: (raw: string) => unknown, dst?: string];

async function ingestTable(
  dir: string, file: string, table: string,
  cols: readonly ColSpec[],
  exec: (statements: { sql: string; params: unknown[] }[]) => Promise<void>,
) {
  const filepath = path.join(dir, file);
  try { await readFile(filepath, { flag: "r" }); }
  catch { console.log(`  · ${file} absent, skipping`); return; }

  await exec([{ sql: `DELETE FROM ${table}`, params: [] }]);

  const placeholders = cols.map((_, i) => `?${i + 1}`).join(",");
  const colNames = cols.map(c => c[2] ?? c[0]).join(",");
  const sql = `INSERT INTO ${table}(${colNames}) VALUES(${placeholders})`;

  const parser = createReadStream(filepath).pipe(parse({ columns: true, trim: true, bom: true }));
  let batch: { sql: string; params: unknown[] }[] = [];
  let total = 0;

  for await (const row of parser) {
    const params = cols.map(([src, transform]) => transform((row as any)[src]));
    batch.push({ sql, params });
    if (batch.length >= BATCH) {
      await exec(batch);
      total += batch.length;
      if (total % 50_000 === 0) console.log(`  · ${table}: ${total.toLocaleString()} rows`);
      batch = [];
    }
  }
  if (batch.length) await exec(batch);
  total += batch.length;
  console.log(`  ✓ ${table}: ${total.toLocaleString()} rows`);
}

async function download(url: string, dest: string) {
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`download ${url} → ${res.status}`);
  await pipeline(res.body as any, createWriteStream(dest));
}

let localDb: DatabaseSync | null = null;
const stmtCache = new Map<string, StatementSync>();

function getLocalDb(): DatabaseSync {
  if (localDb) return localDb;
  // miniflare stores each D1 binding as a content-hashed .sqlite file under
  // backend/.wrangler/state/v3/d1/miniflare-D1DatabaseObject/. There's only
  // one data file (everything else is metadata.sqlite).
  const dir = path.resolve(__dirname, "../.wrangler/state/v3/d1/miniflare-D1DatabaseObject");
  let entries: string[];
  try { entries = readdirSync(dir); }
  catch { throw new Error(
    `Local D1 not initialised at ${dir}. Run \`npm run schema:apply:local\` first.`
  ); }
  const dataFile = entries.find(f => f.endsWith(".sqlite") && f !== "metadata.sqlite");
  if (!dataFile) throw new Error(`No D1 data file in ${dir}`);
  localDb = new DatabaseSync(path.join(dir, dataFile));
  localDb.exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
  return localDb;
}

async function execLocal(statements: { sql: string; params: unknown[] }[]) {
  const db = getLocalDb();
  db.exec("BEGIN");
  try {
    for (const s of statements) {
      let stmt = stmtCache.get(s.sql);
      if (!stmt) {
        stmt = db.prepare(s.sql);
        stmtCache.set(s.sql, stmt);
      }
      // node:sqlite rejects `undefined`; coerce to null defensively.
      const safe = s.params.map(p => p === undefined ? null : p);
      stmt.run(...(safe as never[]));
    }
    db.exec("COMMIT");
  } catch (err) {
    db.exec("ROLLBACK");
    throw err;
  }
}

async function execRemote(statements: { sql: string; params: unknown[] }[]) {
  const accountId = required("CF_ACCOUNT_ID");
  const dbId = required("CF_D1_DATABASE_ID");
  const token = required("CF_API_TOKEN");
  const url = `https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database/${dbId}/query`;
  // D1 HTTP API accepts an array of statements per request.
  const body = JSON.stringify(statements.map(s => ({ sql: s.sql, params: s.params })));
  const res = await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body,
  });
  if (!res.ok) {
    throw new Error(`D1 HTTP ${res.status}: ${await res.text()}`);
  }
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env var ${name}`);
  return v;
}

main().catch(err => { console.error(err); process.exit(1); });
