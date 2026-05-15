/**
 * Row-count comparison between remote D1 and the live GTFS feed.
 * Use after `npm run seed` to verify each table loaded fully.
 *
 *   table          remote      source        %
 *   ───────────────────────────────────────────
 *   agencies            2          2   100.0%  ✓
 *   stops          12,503     12,503   100.0%  ✓
 *   stop_times          0  1,247,891     0.0%
 *
 * Env: D1_ACCOUNT_ID, D1_API_TOKEN, D1_DATABASE_ID (same as seed).
 */
import { createWriteStream, createReadStream } from "node:fs";
import { mkdir, rm } from "node:fs/promises";
import { pipeline } from "node:stream/promises";
import { tmpdir } from "node:os";
import path from "node:path";
// @ts-expect-error — unzipper ships no types.
import unzipper from "unzipper";
import { parse } from "csv-parse";

const GTFS_URL = process.env.TRANSLINK_GTFS_URL
  ?? "https://gtfsrt.api.translink.com.au/GTFS/SEQ_GTFS.zip";

const TABLES: ReadonlyArray<{ table: string; file: string }> = [
  { table: "agencies",       file: "agency.txt" },
  { table: "calendar",       file: "calendar.txt" },
  { table: "calendar_dates", file: "calendar_dates.txt" },
  { table: "routes",         file: "routes.txt" },
  { table: "stops",          file: "stops.txt" },
  { table: "trips",          file: "trips.txt" },
  { table: "stop_times",     file: "stop_times.txt" },
];

interface Row { table: string; remote: number; source: number }

async function main() {
  const accountId = required("D1_ACCOUNT_ID");
  const dbId = required("D1_DATABASE_ID");
  const token = required("D1_API_TOKEN");
  const endpoint = `https://api.cloudflare.com/client/v4/accounts/${accountId}/d1/database/${dbId}/query`;

  console.log("↓ downloading GTFS feed to count source rows…");
  const work = path.join(tmpdir(), `translink-status-${Date.now()}`);
  await mkdir(work, { recursive: true });
  const zipPath = path.join(work, "gtfs.zip");
  await download(GTFS_URL, zipPath);
  const extractDir = path.join(work, "extracted");
  await mkdir(extractDir, { recursive: true });
  await pipeline(createReadStream(zipPath), unzipper.Extract({ path: extractDir }));

  const rows: Row[] = [];
  for (const { table, file } of TABLES) {
    const [remote, source] = await Promise.all([
      countRemote(endpoint, token, table),
      countCsv(path.join(extractDir, file)),
    ]);
    rows.push({ table, remote, source });
  }

  const lastIngest = await fetchLastIngest(endpoint, token);
  await rm(work, { recursive: true, force: true });
  printTable(rows);
  if (lastIngest) console.log(`\nlast_ingest: ${lastIngest}`);
}

async function countRemote(endpoint: string, token: string, table: string): Promise<number> {
  const res = await fetch(endpoint, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ sql: `SELECT COUNT(*) AS n FROM ${table}`, params: [] }),
  });
  if (!res.ok) throw new Error(`D1 HTTP ${res.status}: ${await res.text()}`);
  const json = await res.json() as { result: { results: { n: number }[] }[] };
  return json.result[0]?.results[0]?.n ?? 0;
}

async function fetchLastIngest(endpoint: string, token: string): Promise<string | null> {
  const res = await fetch(endpoint, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      sql: `SELECT value FROM feed_meta WHERE key = 'last_ingest' LIMIT 1`, params: [],
    }),
  });
  if (!res.ok) return null;
  const json = await res.json() as { result: { results: { value: string }[] }[] };
  return json.result[0]?.results[0]?.value ?? null;
}

async function countCsv(filepath: string): Promise<number> {
  let n = 0;
  const parser = createReadStream(filepath).pipe(parse({ columns: true, trim: true, bom: true }));
  for await (const _ of parser) n++;
  return n;
}

function printTable(rows: Row[]) {
  const fmt = (n: number) => n.toLocaleString();
  const tableW = Math.max(5, ...rows.map(r => r.table.length));
  const remoteW = Math.max(6, ...rows.map(r => fmt(r.remote).length));
  const sourceW = Math.max(6, ...rows.map(r => fmt(r.source).length));
  const pad = (s: string, w: number, right = false) =>
    right ? s.padStart(w) : s.padEnd(w);

  console.log("");
  console.log(
    `${pad("table", tableW)}  ${pad("remote", remoteW, true)}  ${pad("source", sourceW, true)}      %`,
  );
  console.log("─".repeat(tableW + remoteW + sourceW + 14));
  for (const r of rows) {
    const pct = r.source === 0
      ? (r.remote === 0 ? "100.0%" : "  n/a ")
      : `${((r.remote / r.source) * 100).toFixed(1)}%`;
    const marker = r.source > 0 && r.remote === r.source ? "✓" : " ";
    console.log(
      `${pad(r.table, tableW)}  ${pad(fmt(r.remote), remoteW, true)}  ${pad(fmt(r.source), sourceW, true)}  ${pad(pct, 7, true)} ${marker}`,
    );
  }
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
