/**
 * Direct-from-laptop GTFS seed for the live D1 database.
 *
 * Runs the full SEQ GTFS feed (agencies → stop_times) in one pass against
 * the Cloudflare D1 REST API. Designed for the $5/mo Workers Paid plan —
 * no daily-budget chunking; the seed finishes in ~30–45 min.
 *
 * Resume points
 * -------------
 * Every 50k rows that have been *acknowledged* by D1, a checkpoint is
 * written to backend/.seed-state.json. If the run is interrupted (Ctrl-C,
 * network drop, laptop sleep), rerunning `npm run seed` resumes from that
 * checkpoint:
 *   - already-completed tables are skipped entirely;
 *   - the current table re-opens its CSV, fast-forwards past the flushed
 *     row count, and continues inserting.
 * Re-attempted rows after a crash are tolerated via INSERT OR IGNORE
 * (every GTFS table has a primary key, so dupes are silently skipped).
 *
 * On a clean finish, both .seed-state.json and the extracted GTFS cache
 * under backend/.seed-cache/ are removed.
 *
 * Free-tier guard
 * ----------------
 * Every run adds its D1 "Rows Written" (deletes + inserts + route_types
 * updates) to a running total stored in feed_meta, keyed to the current
 * billing cycle (anchored on BILLING_CYCLE_ANCHOR_DAY). `--if-changed` runs
 * check this total first: if another full reseed could push the cycle over
 * the 49.5M soft cap (500K buffer below Cloudflare's 50M billing threshold),
 * the run logs and exits without seeding, leaving feed_content_hash untouched
 * so the next scheduled run re-checks once the cycle resets. Manual
 * `npm run seed` / `--restart` runs bypass the hard suspend but emit a
 * warning when approaching the cap, and still count toward the tracked total.
 *
 * Env (backend/.env):
 *   D1_ACCOUNT_ID, D1_API_TOKEN, D1_DATABASE_ID
 *   D1_BILLING_CYCLE_DAY  Optional override for the billing-cycle anchor day
 *                         (default 13, per the Cloudflare invoice).
 *
 * Flags:
 *   --parallel N     In-flight HTTP requests to D1 (default 8).
 *   --restart        Clear checkpoint + cache and start over. Wipes
 *                    every GTFS table on the remote DB first.
 *
 * Usage:
 *   npm run seed                # fresh run, or auto-resume if state exists
 *   npm run seed -- --restart   # wipe everything and start over
 *   npm run seed -- --parallel 16
 */
import {
  createWriteStream, createReadStream,
  existsSync, readFileSync, writeFileSync, mkdirSync, rmSync, renameSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { pipeline } from "node:stream/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
// @ts-expect-error — unzipper ships no types; runtime contract is stable.
import unzipper from "unzipper";
import { parse } from "csv-parse";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = path.resolve(__dirname, "..");
const STATE_FILE = path.join(BACKEND_DIR, ".seed-state.json");
const CACHE_DIR = path.join(BACKEND_DIR, ".seed-cache");
const GTFS_ZIP = path.join(CACHE_DIR, "gtfs.zip");
const GTFS_EXTRACTED = path.join(CACHE_DIR, "extracted");

const GTFS_URL = process.env.TRANSLINK_GTFS_URL
  ?? "https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip";
const D1_PARAM_LIMIT = 100;         // D1 caps bound parameters at ?1..?100
const DEFAULT_PARALLEL = 8;
const CHECKPOINT_EVERY = 50_000;

// D1's "Rows Written" billing metric: 50M/month included on Workers Paid,
// then $1/million. We use a 49.5M soft cap to keep a 500K safety buffer
// below Cloudflare's actual billing threshold.
const D1_FREE_ROWS_WRITTEN_PER_MONTH = 49_500_000;
// Conservative upper bound for a full reseed's D1 "Rows Written" charge.
// This is NOT the same as the row count in the CSVs — D1 bills each index
// entry as a separate write, so inserts into indexed tables cost 2–3×.
//
// Measured breakdown per seed (2.69M stop_times feed, post idx_stoptimes_trip drop):
//   stop_times  2.69M rows × 2 indexes → ~5.94M writes (inserts + deletes)
//   trips        101K rows × 2 indexes → ~250K writes
//   stops         13K rows × 3 indexes → ~55K writes
//   other tables + route_types updates → ~15K writes
//   Total actual:                        ~6.3M writes/seed
//
// Using 14M gives a ~120% buffer over measured cost to absorb feed growth.
// With 14M/seed the guard allows 7 seeds before suspending:
//   after 7 seeds: 7 × 6.3M = 44.1M written; 44.1M + 14M = 58.1M > 49.5M
//   → seed 8 is suspended. Period total stays well under the 49.5M soft cap.
const ESTIMATED_FULL_RESEED_ROWS = 14_000_000;
// Day-of-month the Cloudflare billing cycle resets (from the invoice: "May
// 13 – Jun 12"). Override with D1_BILLING_CYCLE_DAY if this drifts.
const BILLING_CYCLE_ANCHOR_DAY = Number(process.env.D1_BILLING_CYCLE_DAY ?? 13);

type ColTransform = (raw: string | undefined) => unknown;
type ColSpec = readonly [src: string, transform: ColTransform, dst?: string];

interface TableSpec {
  file: string;
  table: string;
  cols: readonly ColSpec[];
}

const TABLES: readonly TableSpec[] = [
  { file: "agency.txt", table: "agencies", cols: [
    ["agency_id", s => s], ["agency_name", s => s],
    ["agency_url", s => s || null], ["agency_timezone", s => s, "agency_tz"],
  ] },
  { file: "calendar.txt", table: "calendar", cols: [
    ["service_id", s => s],
    ["monday", s => Number(s)], ["tuesday", s => Number(s)],
    ["wednesday", s => Number(s)], ["thursday", s => Number(s)],
    ["friday", s => Number(s)], ["saturday", s => Number(s)],
    ["sunday", s => Number(s)],
    ["start_date", s => s], ["end_date", s => s],
  ] },
  { file: "calendar_dates.txt", table: "calendar_dates", cols: [
    ["service_id", s => s], ["date", s => s],
    ["exception_type", s => Number(s)],
  ] },
  { file: "routes.txt", table: "routes", cols: [
    ["route_id", s => s], ["agency_id", s => s || null],
    ["route_short_name", s => s || null], ["route_long_name", s => s || null],
    ["route_type", s => Number(s)],
    ["route_color", s => s || null], ["route_text_color", s => s || null],
  ] },
  { file: "stops.txt", table: "stops", cols: [
    ["stop_id", s => s], ["stop_code", s => s || null], ["stop_name", s => s],
    ["stop_lat", s => Number(s)], ["stop_lon", s => Number(s)],
    ["location_type", s => Number(s ?? 0)],
    ["parent_station", s => s || null], ["platform_code", s => s || null],
  ] },
  { file: "trips.txt", table: "trips", cols: [
    ["trip_id", s => s], ["route_id", s => s], ["service_id", s => s],
    ["trip_headsign", s => s || null],
    ["direction_id", s => s == null || s === "" ? null : Number(s)],
    ["shape_id", s => s || null], ["block_id", s => s || null],
  ] },
  { file: "stop_times.txt", table: "stop_times", cols: [
    ["trip_id", s => s],
    ["arrival_time", s => s], ["departure_time", s => s],
    ["stop_id", s => s], ["stop_sequence", s => Number(s)],
    ["pickup_type", s => Number(s ?? 0)],
    ["drop_off_type", s => Number(s ?? 0)],
  ] },
];

interface CheckpointState {
  gtfs_url: string;
  started_at: string;
  completed_tables: string[];
  current: { table: string; rows_written: number } | null;
}

interface CliArgs {
  parallel: number;
  restart: boolean;
  ifChanged: boolean;
}

function parseArgs(argv: string[]): CliArgs {
  let parallel = DEFAULT_PARALLEL;
  let restart = false;
  let ifChanged = false;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--parallel") parallel = Number(argv[++i]);
    else if (a === "--restart") restart = true;
    else if (a === "--if-changed") ifChanged = true;
    else if (a === "-h" || a === "--help") {
      console.log("Usage: seed [--parallel N] [--restart] [--if-changed]");
      process.exit(0);
    } else throw new Error(`unknown flag: ${a}`);
  }
  if (!Number.isFinite(parallel) || parallel < 1) parallel = DEFAULT_PARALLEL;
  return { parallel, restart, ifChanged };
}

/**
 * SHA-256 over the concatenation of the GTFS .txt files we actually ingest,
 * in TABLES order. Upstream re-packages the feed (new ETag/Last-Modified)
 * far more often than the schedule data inside actually changes, so the
 * hash of the extracted CSVs is the only reliable "did anything change?"
 * signal for `--if-changed`.
 */
async function computeFeedHash(extractedDir: string): Promise<string> {
  const hash = createHash("sha256");
  for (const spec of TABLES) {
    for await (const chunk of createReadStream(path.join(extractedDir, spec.file))) {
      hash.update(chunk as Buffer);
    }
  }
  return hash.digest("hex");
}

async function fetchStoredHash(d1: D1Client): Promise<string | null> {
  const rows = await d1.query<{ value: string }>(
    `SELECT value FROM feed_meta WHERE key = 'feed_content_hash' LIMIT 1`,
  );
  return rows[0]?.value ?? null;
}

/** Most recent billing-cycle start date (YYYY-MM-DD) on or before `now`. */
function currentBillingPeriodStart(now: Date): string {
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), BILLING_CYCLE_ANCHOR_DAY));
  if (d.getTime() > now.getTime()) d.setUTCMonth(d.getUTCMonth() - 1);
  return d.toISOString().slice(0, 10);
}

/** The day the *next* billing cycle starts, given the current cycle's start date. */
function nextBillingPeriodStart(periodStart: string): string {
  const d = new Date(`${periodStart}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1);
  return d.toISOString().slice(0, 10);
}

interface UsageState {
  periodStart: string;
  rowsWritten: number;
}

/**
 * Self-tracked running total of D1 "Rows Written" for the current billing
 * cycle. The seed script is the only D1 writer in this project, so this
 * counter — reset whenever the stored period start has rolled over — is a
 * close enough proxy for the Cloudflare-billed metric to act as a circuit
 * breaker.
 */
async function loadUsage(d1: D1Client): Promise<UsageState | null> {
  const rows = await d1.query<{ key: string; value: string }>(
    `SELECT key, value FROM feed_meta WHERE key IN ('d1_usage_period_start', 'd1_usage_rows_written')`,
  );
  const map = new Map(rows.map(r => [r.key, r.value]));
  const periodStart = map.get("d1_usage_period_start");
  const rowsWritten = map.get("d1_usage_rows_written");
  if (!periodStart || rowsWritten === undefined) return null;
  return { periodStart, rowsWritten: Number(rowsWritten) };
}

async function saveUsage(d1: D1Client, usage: UsageState): Promise<void> {
  const nowUnix = Math.floor(Date.now() / 1000);
  for (const [key, value] of [
    ["d1_usage_period_start", usage.periodStart],
    ["d1_usage_rows_written", String(usage.rowsWritten)],
  ] as const) {
    await d1.exec(
      `INSERT INTO feed_meta(key, value, updated_at)
       VALUES(?1, ?2, ?3)
       ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
      [key, value, nowUnix],
    );
  }
}

function loadCheckpoint(): CheckpointState | null {
  if (!existsSync(STATE_FILE)) return null;
  try { return JSON.parse(readFileSync(STATE_FILE, "utf8")) as CheckpointState; }
  catch { return null; }
}

function saveCheckpoint(s: CheckpointState): void {
  // Atomic write — rename is atomic on POSIX; avoids half-written JSON if
  // the process is killed mid-write.
  const tmp = STATE_FILE + ".tmp";
  writeFileSync(tmp, JSON.stringify(s, null, 2));
  renameSync(tmp, STATE_FILE);
}

function clearCheckpoint(): void {
  if (existsSync(STATE_FILE)) rmSync(STATE_FILE);
  if (existsSync(CACHE_DIR)) rmSync(CACHE_DIR, { recursive: true, force: true });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const accountId = required("D1_ACCOUNT_ID");
  const dbId = required("D1_DATABASE_ID");
  const token = required("D1_API_TOKEN");
  const endpoint = `https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database/${dbId}/query`;
  const d1 = makeClient(endpoint, token);

  if (args.restart) {
    // Clear the local checkpoint + cache now so loadCheckpoint() below
    // returns null (resuming = false). The actual D1 table wipes happen
    // later, inside the try/catch, so partial delete costs are tracked.
    console.log("↻ --restart: clearing checkpoint and cache");
    clearCheckpoint();
  }

  const cp = loadCheckpoint();
  const resuming = cp !== null;
  const state: CheckpointState = cp ?? {
    gtfs_url: GTFS_URL,
    started_at: new Date().toISOString(),
    completed_tables: [],
    current: null,
  };

  console.log(
    resuming
      ? `↻ resuming: ${state.completed_tables.length}/${TABLES.length} tables done`
        + (state.current ? `; current=${state.current.table} @ ${state.current.rows_written.toLocaleString()} rows` : "")
      : `→ fresh seed · parallel=${args.parallel}`,
  );

  // Free-tier guard: load usage and check BEFORE downloading the feed so
  // that suspended automated runs don't waste time on a ~50 MB download.
  // --if-changed (cron) runs are hard-suspended when approaching the soft
  // cap; manual runs bypass the suspend but receive a warning so the
  // operator knows they may be incurring charges. Either way the writes
  // are counted toward the tracked total at the end of the run.
  const periodStart = currentBillingPeriodStart(new Date());
  let usage = await loadUsage(d1);
  if (!usage || usage.periodStart !== periodStart) {
    usage = { periodStart, rowsWritten: 0 };
  }
  if (
    args.ifChanged && !resuming
    && usage.rowsWritten + ESTIMATED_FULL_RESEED_ROWS > D1_FREE_ROWS_WRITTEN_PER_MONTH
  ) {
    console.log(
      `⏸ D1 free-tier guard: ${usage.rowsWritten.toLocaleString()} rows written this cycle `
      + `(since ${usage.periodStart}); a full reseed (~${ESTIMATED_FULL_RESEED_ROWS.toLocaleString()} rows) `
      + `could exceed the ${D1_FREE_ROWS_WRITTEN_PER_MONTH.toLocaleString()} soft cap. `
      + `Suspending until the cycle resets on ${nextBillingPeriodStart(usage.periodStart)}.`,
    );
    await saveUsage(d1, usage);
    clearCheckpoint();
    return;
  }
  if (
    !args.ifChanged && !resuming
    && usage.rowsWritten + ESTIMATED_FULL_RESEED_ROWS > D1_FREE_ROWS_WRITTEN_PER_MONTH
  ) {
    console.warn(
      `  ⚠ D1 free-tier warning: ${usage.rowsWritten.toLocaleString()} rows written this cycle `
      + `(since ${usage.periodStart}); a full reseed (~${ESTIMATED_FULL_RESEED_ROWS.toLocaleString()} rows) `
      + `may exceed the ${D1_FREE_ROWS_WRITTEN_PER_MONTH.toLocaleString()} soft cap. `
      + `Proceeding because this is a manual run — charges may apply.`,
    );
  }

  await ensureGtfsExtracted(resuming);

  // --if-changed: short-circuit when the downloaded feed's content hash
  // matches what we stamped at the last successful seed. Only applies on a
  // fresh run — a pending checkpoint always wins, so we finish what we
  // started before deciding whether the upstream has moved on.
  let contentHash: string | null = null;
  if (args.ifChanged && !resuming) {
    contentHash = await computeFeedHash(GTFS_EXTRACTED);
    const storedHash = await fetchStoredHash(d1);
    if (storedHash === contentHash) {
      console.log(`✓ feed content unchanged (hash=${contentHash.slice(0, 12)}…); no seed needed`);
      clearCheckpoint();
      return;
    }
    console.log(
      `→ feed content changed (${storedHash?.slice(0, 12) ?? "none"} → ${contentHash.slice(0, 12)}…); seeding`,
    );
  }

  const startedAt = Date.now();
  let totalRows = 0;

  try {
  // --restart: wipe all GTFS tables in D1. Inside the try/catch so that
  // any partial delete costs are captured in d1.rowsWritten and persisted
  // to the free-tier guard's running total even if a delete fails.
  if (args.restart) {
    console.log("→ wiping GTFS tables in D1");
    for (const t of TABLES) {
      await d1.exec(`DELETE FROM ${t.table}`);
    }
    // Also clear feed_content_hash so that if this restart seed fails
    // partway through, the next --if-changed cron doesn't see "hash
    // unchanged → no seed needed" and silently leave the DB half-empty.
    await d1.exec(`DELETE FROM feed_meta WHERE key IN ('last_ingest', 'feed_content_hash')`);
  }

  for (const spec of TABLES) {
    if (state.completed_tables.includes(spec.table)) {
      console.log(`  · ${spec.table}: already complete, skipping`);
      continue;
    }
    const skipRows = state.current?.table === spec.table
      ? state.current.rows_written
      : 0;

    // On a fresh start for this table (not resuming mid-table), wipe it.
    // Otherwise the table is already partially populated and we resume.
    if (skipRows === 0 && !args.restart) {
      await d1.exec(`DELETE FROM ${spec.table}`);
    }

    if (!state.current || state.current.table !== spec.table) {
      state.current = { table: spec.table, rows_written: skipRows };
      saveCheckpoint(state);
    }

    const tStart = Date.now();
    const written = await ingestTable(
      path.join(GTFS_EXTRACTED, spec.file),
      spec, d1, args.parallel, skipRows, state,
    );
    totalRows += written;
    state.completed_tables.push(spec.table);
    state.current = null;
    saveCheckpoint(state);
    const secs = Math.round((Date.now() - tStart) / 1000);
    console.log(`  ✓ ${spec.table}: ${written.toLocaleString()} rows in ${secs}s`);
  }

  await deriveRouteTypes(d1, args.parallel);

  // Stamp last_ingest + feed_content_hash so the next --if-changed run can
  // tell whether the schedule actually moved. contentHash was already
  // computed above unless this was a manual run without --if-changed.
  contentHash ??= await computeFeedHash(GTFS_EXTRACTED);
  const nowIso = new Date().toISOString();
  const nowUnix = Math.floor(Date.now() / 1000);
  await d1.exec(
    `INSERT INTO feed_meta(key, value, updated_at)
     VALUES('last_ingest', ?1, ?2)
     ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
    [nowIso, nowUnix],
  );
  await d1.exec(
    `INSERT INTO feed_meta(key, value, updated_at)
     VALUES('feed_content_hash', ?1, ?2)
     ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
    [contentHash, nowUnix],
  );

  // Record actual D1 rows-written billed this run (read directly from
  // meta.rows_written in every API response — includes all index-entry
  // writes, so it matches what Cloudflare charges exactly).
  usage.rowsWritten += d1.rowsWritten;
  await saveUsage(d1, usage);
  console.log(
    `  · D1 usage this cycle (since ${usage.periodStart}): `
    + `${usage.rowsWritten.toLocaleString()}/${D1_FREE_ROWS_WRITTEN_PER_MONTH.toLocaleString()} rows written`,
  );
  if (usage.rowsWritten >= D1_FREE_ROWS_WRITTEN_PER_MONTH) {
    console.warn(
      `  ⚠ Free-tier limit reached (${usage.rowsWritten.toLocaleString()} rows written this cycle). `
      + `Automated seeds suspended until the cycle resets on ${nextBillingPeriodStart(usage.periodStart)}.`,
    );
  }
  } catch (err) {
    // Persist whatever writes accumulated before the failure so the
    // free-tier guard sees them on the next run. Without this, failed runs
    // rack up untracked D1 charges that the guard can't account for.
    if (d1.rowsWritten > 0) {
      usage.rowsWritten += d1.rowsWritten;
      await saveUsage(d1, usage).catch(() => {});
      console.warn(
        `  ⚠ seed failed — partial D1 usage recorded: `
        + `${usage.rowsWritten.toLocaleString()}/${D1_FREE_ROWS_WRITTEN_PER_MONTH.toLocaleString()} rows written this cycle`,
      );
    }
    throw err;
  }

  clearCheckpoint();

  const totalSecs = Math.round((Date.now() - startedAt) / 1000);
  const mins = Math.floor(totalSecs / 60);
  const secs = totalSecs % 60;
  console.log(`🎉 seed complete: ${totalRows.toLocaleString()} new rows in ${mins}m${secs}s`);
}

/**
 * Ensure backend/.seed-cache/extracted/ has the GTFS .txt files.
 * On resume, reuses the previously-extracted feed (skips ~50 MB download).
 * On fresh start, downloads + extracts.
 */
async function ensureGtfsExtracted(resuming: boolean): Promise<void> {
  const haveExtracted = existsSync(path.join(GTFS_EXTRACTED, "stop_times.txt"));
  if (resuming && haveExtracted) {
    console.log("⤓ reusing cached GTFS extraction");
    return;
  }
  if (existsSync(CACHE_DIR)) rmSync(CACHE_DIR, { recursive: true, force: true });
  mkdirSync(GTFS_EXTRACTED, { recursive: true });
  console.log("↓ downloading GTFS feed");
  await download(GTFS_URL, GTFS_ZIP);
  console.log("⤓ extracting");
  await pipeline(createReadStream(GTFS_ZIP), unzipper.Extract({ path: GTFS_EXTRACTED }));
}

/**
 * Populate stops.route_types via correlated subquery, chunked by stop_id.
 *
 * The naive one-shot UPDATE (`UPDATE stops SET route_types = (SELECT … WHERE
 * stop_id = stops.stop_id)`) trips D1's per-query CPU limit (error 7429) on
 * the full feed — it asks the engine to evaluate the join for every one of
 * ~13k stops in a single transaction. Chunking by stop_id keeps each query
 * well under D1's budget, and the concurrency pool fans the work out so
 * the whole derivation completes in well under a minute.
 *
 * The UPDATE is naturally idempotent (re-running over the same stop sets
 * the same value), so this is safe to retry on a partial failure.
 */
async function deriveRouteTypes(d1: D1Client, parallel: number): Promise<void> {
  console.log("→ deriving route_types per stop (chunked)");
  const stopIds = (await d1.query<{ stop_id: string }>(`SELECT stop_id FROM stops`))
    .map(r => r.stop_id);
  const CHUNK = 50;
  const pool = new ConcurrencyPool(parallel);
  let done = 0;
  for (let i = 0; i < stopIds.length; i += CHUNK) {
    const ids = stopIds.slice(i, i + CHUNK);
    const placeholders = ids.map((_, j) => `?${j + 1}`).join(",");
    const sql = `UPDATE stops SET route_types = (
      SELECT GROUP_CONCAT(DISTINCT r.route_type)
      FROM stop_times st
      JOIN trips t ON t.trip_id = st.trip_id
      JOIN routes r ON r.route_id = t.route_id
      WHERE st.stop_id = stops.stop_id
    ) WHERE stop_id IN (${placeholders})`;
    await pool.run(async () => {
      await d1.exec(sql, ids);
      done += ids.length;
      process.stdout.write(`\r  · route_types: ${done.toLocaleString()}/${stopIds.length.toLocaleString()} stops  `);
    });
  }
  await pool.drain();
  process.stdout.write("\r" + " ".repeat(60) + "\r");
  console.log(`  ✓ route_types: ${stopIds.length.toLocaleString()} stops`);
}

/**
 * Stream one GTFS .txt into its D1 table.
 *
 * - `skipRows` lets us resume mid-table: the CSV parser yields rows but we
 *   discard the first N (already inserted before the previous crash).
 * - Batches of `rowsPerStmt` are dispatched through a bounded concurrency
 *   pool. Each batch has a sequence number; ACKs are tracked in order so
 *   the checkpoint represents the highest row index where *every* preceding
 *   batch has been confirmed by D1.
 * - Returns the number of rows newly written this run (not including
 *   skipped rows).
 */
async function ingestTable(
  filepath: string, spec: TableSpec,
  d1: D1Client, parallel: number,
  skipRows: number, state: CheckpointState,
): Promise<number> {
  const colNames = spec.cols.map(c => c[2] ?? c[0]).join(",");
  const rowsPerStmt = Math.max(1, Math.floor(D1_PARAM_LIMIT / spec.cols.length));
  const parser = createReadStream(filepath).pipe(parse({ columns: true, trim: true, bom: true }));

  let rowIdx = 0;
  let written = 0;
  let rowBuf: unknown[][] = [];
  const pool = new ConcurrencyPool(parallel);
  const ack = new OrderedAck();
  let lastCheckpointAt = skipRows;

  const flush = async () => {
    if (rowBuf.length === 0) return;
    const batch = rowBuf;
    rowBuf = [];
    const ncols = spec.cols.length;
    const rowPlaceholders = batch.map((_, ri) =>
      "(" + spec.cols.map((_, ci) => `?${ri * ncols + ci + 1}`).join(",") + ")"
    ).join(",");
    // OR IGNORE: protects against the at-most-handful of duplicate inserts
    // that can occur on resume — if batches were in-flight when the previous
    // run crashed, those rows may already exist. Every GTFS table has a
    // primary key, so collisions are silently skipped instead of aborting.
    const sql = `INSERT OR IGNORE INTO ${spec.table}(${colNames}) VALUES ${rowPlaceholders}`;
    const params = batch.flat();
    const seq = ack.reserve(skipRows + written);
    await pool.run(async () => {
      await d1.exec(sql, params);
      const newFlushed = ack.complete(seq);
      if (newFlushed !== null && newFlushed - lastCheckpointAt >= CHECKPOINT_EVERY) {
        state.current = { table: spec.table, rows_written: newFlushed };
        saveCheckpoint(state);
        lastCheckpointAt = newFlushed;
        process.stdout.write(`\r  · ${spec.table}: ${newFlushed.toLocaleString()} rows acked  `);
      }
    });
  };

  for await (const row of parser) {
    rowIdx++;
    if (rowIdx <= skipRows) continue;
    const params = spec.cols.map(([src, transform]) => {
      const v = transform((row as Record<string, string>)[src]);
      return v === undefined ? null : v;
    });
    rowBuf.push(params);
    written++;
    if (rowBuf.length >= rowsPerStmt) await flush();
  }
  await flush();
  await pool.drain();

  // Final checkpoint stamp for this table (covers the trailing < CHECKPOINT_EVERY rows).
  const finalFlushed = skipRows + written;
  if (finalFlushed > lastCheckpointAt) {
    state.current = { table: spec.table, rows_written: finalFlushed };
    saveCheckpoint(state);
    process.stdout.write("\r" + " ".repeat(60) + "\r");
  }
  return written;
}

/**
 * Tracks batch ACKs in dispatch order so the seed checkpoint always
 * reflects a contiguous prefix of inserted rows.
 *
 * Each call to `reserve()` returns a sequence number (0, 1, 2, …) bound to
 * an `endRow` (cumulative rows written through end of this batch).
 * `complete(seq)` marks that batch's ACK. We then advance the "flushed"
 * watermark as far as the next-expected sequence has been completed.
 * Returns the new flushed row count if it advanced, else null.
 */
class OrderedAck {
  private nextSeq = 0;
  private pending = new Map<number, { endRow: number; done: boolean }>();
  private nextToCommit = 0;
  flushedRow = 0;

  reserve(endRow: number): number {
    const seq = this.nextSeq++;
    this.pending.set(seq, { endRow, done: false });
    return seq;
  }

  complete(seq: number): number | null {
    const e = this.pending.get(seq);
    if (!e) return null;
    e.done = true;
    let advanced = false;
    while (true) {
      const next = this.pending.get(this.nextToCommit);
      if (!next || !next.done) break;
      this.flushedRow = next.endRow;
      this.pending.delete(this.nextToCommit);
      this.nextToCommit++;
      advanced = true;
    }
    return advanced ? this.flushedRow : null;
  }
}

class ConcurrencyPool {
  private active = new Set<Promise<unknown>>();
  private firstError: unknown = null;

  constructor(private readonly limit: number) {}

  async run<T>(task: () => Promise<T>): Promise<void> {
    while (this.active.size >= this.limit) {
      await Promise.race(this.active);
    }
    if (this.firstError) throw this.firstError;
    const p = task().catch(err => {
      if (!this.firstError) this.firstError = err;
    }) as Promise<unknown>;
    this.active.add(p);
    p.finally(() => this.active.delete(p));
  }

  async drain(): Promise<void> {
    while (this.active.size > 0) {
      await Promise.race(this.active);
    }
    if (this.firstError) throw this.firstError;
  }
}

interface D1Client {
  exec: (sql: string, params?: unknown[]) => Promise<void>;
  query: <T = Record<string, unknown>>(sql: string, params?: unknown[]) => Promise<T[]>;
  /** Running total of D1 "rows written" billed by Cloudflare for this client
   *  instance, read directly from the `meta.rows_written` field returned by
   *  every query response. Includes index-entry writes, so it matches what
   *  Cloudflare actually charges — unlike manually counting inserted rows. */
  readonly rowsWritten: number;
}

function makeClient(endpoint: string, token: string): D1Client {
  let _rowsWritten = 0;
  const MAX_RETRIES = 6;
  async function call(sql: string, params: unknown[]) {
    let lastErr: unknown;
    for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
      try {
        const res = await fetch(endpoint, {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({ sql, params }),
        });
        if (!res.ok) {
          if (res.status >= 500 && attempt < MAX_RETRIES - 1) {
            lastErr = new Error(`D1 HTTP ${res.status}`);
            await sleep(backoffMs(attempt));
            continue;
          }
          throw new Error(`D1 HTTP ${res.status}: ${await res.text()}`);
        }
        return await res.json() as { result: { results: unknown[]; meta: { rows_written: number } }[]; success: boolean };
      } catch (err) {
        lastErr = err;
        const code = (err as { cause?: { code?: string }; code?: string })?.cause?.code
                   ?? (err as { code?: string })?.code;
        const isTransient = code === "UND_ERR_SOCKET"
          || code === "UND_ERR_CONNECT_TIMEOUT"
          || code === "ECONNRESET"
          || /fetch failed/i.test(String((err as Error)?.message));
        if (!isTransient || attempt === MAX_RETRIES - 1) throw err;
        await sleep(backoffMs(attempt));
      }
    }
    throw lastErr;
  }
  return {
    exec: async (sql, params = []) => {
      const json = await call(sql, params);
      _rowsWritten += (json.result[0]?.meta as { rows_written?: number })?.rows_written ?? 0;
    },
    query: async <T = Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T[]> => {
      const json = await call(sql, params);
      _rowsWritten += (json.result[0]?.meta as { rows_written?: number })?.rows_written ?? 0;
      return (json.result[0]?.results ?? []) as T[];
    },
    get rowsWritten() { return _rowsWritten; },
  };
}

function backoffMs(attempt: number): number {
  return 500 * Math.pow(2, attempt);  // 500ms, 1s, 2s, 4s, 8s, 16s
}

function sleep(ms: number): Promise<void> {
  return new Promise(r => setTimeout(r, ms));
}

async function download(url: string, dest: string) {
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`download ${url} → ${res.status}`);
  await pipeline(res.body as unknown as NodeJS.ReadableStream, createWriteStream(dest));
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env var ${name}`);
  return v;
}

main().catch(err => { console.error(err); process.exit(1); });
