/**
 * Chunked GTFS seed for remote D1, sized to fit under the free-tier
 * 100K writes/day limit. Each run picks up where the previous one left
 * off (state stored in feed_meta.chunked_progress). After ~30 daily runs
 * the full feed is loaded and route_types is derived.
 *
 * Env vars (put in backend/.env). The CF_ namespace is avoided so wrangler
 * (which auto-loads .env) doesn't pick up our scoped D1 token and use it for
 * its own deploys — it should keep using the OAuth session from `wrangler login`.
 *   D1_ACCOUNT_ID
 *   D1_API_TOKEN          // token with D1:Edit on the database
 *   D1_DATABASE_ID
 *   SEED_BUDGET=80000     // optional; rows to write this run
 *
 * Usage:  npm run seed:remote
 */
import { createWriteStream, createReadStream } from "node:fs";
import { mkdir, rm } from "node:fs/promises";
import { pipeline } from "node:stream/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import unzipper from "unzipper";
import { parse } from "csv-parse";

const GTFS_URL = process.env.TRANSLINK_GTFS_URL
  ?? "https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip";
const DEFAULT_BUDGET = 80_000;
const D1_PARAM_LIMIT = 100;         // D1 caps bound parameters at ?1..?100
const FINALIZE_RESERVE = 14_000;    // budget to keep for route_types derivation

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

interface Progress {
  tableIdx: number;
  offset: number;
  finalized: boolean;
}

async function main() {
  const accountId = required("D1_ACCOUNT_ID");
  const dbId = required("D1_DATABASE_ID");
  const token = required("D1_API_TOKEN");
  const endpoint = `https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database/${dbId}/query`;
  const budget = Number(process.env.SEED_BUDGET ?? DEFAULT_BUDGET);

  const d1 = makeClient(endpoint, token);
  const progress = await readProgress(d1);

  if (progress.finalized) {
    console.log("✓ seed already complete; nothing to do");
    return;
  }

  const tableLabel = TABLES[progress.tableIdx]?.table ?? "(done)";
  console.log(`resuming at table[${progress.tableIdx}] '${tableLabel}' offset=${progress.offset.toLocaleString()}, budget=${budget.toLocaleString()}`);

  const work = path.join(tmpdir(), `translink-gtfs-${Date.now()}`);
  await mkdir(work, { recursive: true });
  const zipPath = path.join(work, "gtfs.zip");
  console.log("↓ downloading GTFS feed");
  await download(GTFS_URL, zipPath);
  const extractDir = path.join(work, "extracted");
  await mkdir(extractDir, { recursive: true });
  console.log("⤓ extracting");
  await pipeline(createReadStream(zipPath), unzipper.Extract({ path: extractDir }));

  let remaining = budget;
  let { tableIdx, offset } = progress;

  while (tableIdx < TABLES.length && remaining > 0) {
    const spec = TABLES[tableIdx];
    if (offset === 0) {
      await d1.exec(`DELETE FROM ${spec.table}`);
    }
    const result = await ingestChunk(
      path.join(extractDir, spec.file), spec, d1, offset, remaining,
    );
    remaining -= result.rowsWritten;
    offset += result.rowsWritten;
    console.log(`  · ${spec.table}: +${result.rowsWritten.toLocaleString()} rows (total ${offset.toLocaleString()})${result.completed ? " ✓" : ""}`);

    await writeProgress(d1, { tableIdx, offset, finalized: false });

    if (result.completed) {
      tableIdx++;
      offset = 0;
    } else {
      break;
    }
  }

  let finalized = false;
  if (tableIdx >= TABLES.length) {
    if (remaining >= FINALIZE_RESERVE) {
      console.log("→ deriving route_types per stop (single correlated UPDATE)");
      // No TEMP tables — each D1 HTTP call is its own connection, so use a
      // self-contained correlated subquery that idempotently fills the column.
      await d1.exec(`UPDATE stops SET route_types = (
        SELECT GROUP_CONCAT(DISTINCT r.route_type)
        FROM stop_times st
        JOIN trips t ON t.trip_id = st.trip_id
        JOIN routes r ON r.route_id = t.route_id
        WHERE st.stop_id = stops.stop_id
      )`);
      await d1.exec(
        `INSERT INTO feed_meta(key, value, updated_at)
         VALUES('last_ingest', ?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
        [new Date().toISOString(), Math.floor(Date.now() / 1000)],
      );
      finalized = true;
    } else {
      console.log(`⚠ raw tables loaded but only ${remaining.toLocaleString()} budget left — finalize needs ~${FINALIZE_RESERVE.toLocaleString()}, run again tomorrow`);
    }
  }

  await writeProgress(d1, { tableIdx, offset, finalized });

  await rm(work, { recursive: true, force: true });

  const used = budget - remaining;
  if (finalized) {
    console.log(`🎉 seed complete (~${used.toLocaleString()} writes this run)`);
  } else {
    console.log(`✓ chunk done (~${used.toLocaleString()} writes this run). Run again tomorrow.`);
  }
}

interface ChunkResult { rowsWritten: number; completed: boolean }

async function ingestChunk(
  filepath: string, spec: TableSpec,
  d1: D1Client, offset: number, budget: number,
): Promise<ChunkResult> {
  const colNames = spec.cols.map(c => c[2] ?? c[0]).join(",");
  const maxRowsPerStmt = Math.max(1, Math.floor(D1_PARAM_LIMIT / spec.cols.length));
  const parser = createReadStream(filepath).pipe(parse({ columns: true, trim: true, bom: true }));

  let skipped = 0;
  let written = 0;
  let rowBuf: unknown[][] = [];
  let completed = true;

  const flush = async () => {
    if (rowBuf.length === 0) return;
    const ncols = spec.cols.length;
    const rowPlaceholders = rowBuf.map((_, ri) =>
      "(" + spec.cols.map((_, ci) => `?${ri * ncols + ci + 1}`).join(",") + ")"
    ).join(",");
    const sql = `INSERT INTO ${spec.table}(${colNames}) VALUES ${rowPlaceholders}`;
    const params = rowBuf.flat();
    await d1.exec(sql, params);
    rowBuf = [];
  };

  for await (const row of parser) {
    if (skipped < offset) { skipped++; continue; }
    if (written >= budget) { completed = false; break; }
    const params = spec.cols.map(([src, transform]) => {
      const v = transform((row as Record<string, string>)[src]);
      return v === undefined ? null : v;
    });
    rowBuf.push(params);
    written++;
    if (rowBuf.length >= maxRowsPerStmt) await flush();
  }
  await flush();
  return { rowsWritten: written, completed };
}

interface D1Client {
  exec: (sql: string, params?: unknown[]) => Promise<void>;
  query: <T = Record<string, unknown>>(sql: string, params?: unknown[]) => Promise<T[]>;
}

function makeClient(endpoint: string, token: string): D1Client {
  async function call(sql: string, params: unknown[]) {
    const res = await fetch(endpoint, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ sql, params }),
    });
    if (!res.ok) {
      throw new Error(`D1 HTTP ${res.status}: ${await res.text()}`);
    }
    return await res.json() as { result: { results: unknown[] }[]; success: boolean };
  }
  return {
    exec: async (sql, params = []) => { await call(sql, params); },
    query: async <T = Record<string, unknown>>(sql: string, params: unknown[] = []): Promise<T[]> => {
      const json = await call(sql, params);
      return (json.result[0]?.results ?? []) as T[];
    },
  };
}

async function readProgress(d1: D1Client): Promise<Progress> {
  const rows = await d1.query<{ value: string }>(
    `SELECT value FROM feed_meta WHERE key = 'chunked_progress' LIMIT 1`,
  );
  if (rows.length === 0) return { tableIdx: 0, offset: 0, finalized: false };
  return JSON.parse(rows[0].value) as Progress;
}

async function writeProgress(d1: D1Client, p: Progress) {
  await d1.exec(
    `INSERT INTO feed_meta(key, value, updated_at)
     VALUES('chunked_progress', ?1, ?2)
     ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`,
    [JSON.stringify(p), Math.floor(Date.now() / 1000)],
  );
}

async function download(url: string, dest: string) {
  const res = await fetch(url);
  if (!res.ok || !res.body) throw new Error(`download ${url} → ${res.status}`);
  await pipeline(res.body as any, createWriteStream(dest));
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env var ${name}`);
  return v;
}

main().catch(err => { console.error(err); process.exit(1); });
