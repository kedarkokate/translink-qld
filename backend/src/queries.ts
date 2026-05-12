import type { Env, Stop, StopWithDistance, Route, Departure } from "./types";
import { boundingBox, haversineMeters } from "./distance";
import { getTripUpdates } from "./gtfsRt";

const BRISBANE_TZ = "Australia/Brisbane";

export async function findNearbyStops(
  env: Env,
  lat: number, lon: number,
  radiusM: number, limit: number,
): Promise<StopWithDistance[]> {
  const bbox = boundingBox(lat, lon, radiusM);
  // Bounding-box prefilter — keeps the scan ~O(stops in bbox), then we
  // compute Haversine and sort in code. ~12K SEQ stops total, so even a
  // generous bbox returns at most a few hundred rows.
  const { results } = await env.DB.prepare(
    `SELECT stop_id, stop_code, stop_name, stop_lat, stop_lon,
            location_type, parent_station, platform_code
     FROM stops
     WHERE stop_lat BETWEEN ?1 AND ?2
       AND stop_lon BETWEEN ?3 AND ?4
       AND location_type = 0`
  )
    .bind(bbox.minLat, bbox.maxLat, bbox.minLon, bbox.maxLon)
    .all<Stop>();

  return (results ?? [])
    .map(s => ({
      ...s,
      distance_m: haversineMeters(lat, lon, s.stop_lat, s.stop_lon),
    }))
    .filter(s => s.distance_m <= radiusM)
    .sort((a, b) => a.distance_m - b.distance_m)
    .slice(0, limit);
}

export async function getStop(env: Env, stopId: string): Promise<Stop | null> {
  return env.DB.prepare(
    `SELECT stop_id, stop_code, stop_name, stop_lat, stop_lon,
            location_type, parent_station, platform_code
     FROM stops WHERE stop_id = ?1`
  ).bind(stopId).first<Stop>();
}

export async function getRoutesForStop(env: Env, stopId: string): Promise<Route[]> {
  const { results } = await env.DB.prepare(
    `SELECT DISTINCT r.route_id, r.route_short_name, r.route_long_name,
            r.route_type, r.route_color, r.route_text_color
     FROM routes r
     JOIN trips t ON t.route_id = r.route_id
     JOIN stop_times st ON st.trip_id = t.trip_id
     WHERE st.stop_id = ?1
     ORDER BY r.route_short_name`
  ).bind(stopId).all<Route>();
  return results ?? [];
}

export async function getRoute(env: Env, routeId: string): Promise<Route | null> {
  return env.DB.prepare(
    `SELECT route_id, route_short_name, route_long_name,
            route_type, route_color, route_text_color
     FROM routes WHERE route_id = ?1`
  ).bind(routeId).first<Route>();
}

interface ScheduledRow {
  trip_id: string;
  route_id: string;
  route_short_name: string | null;
  route_long_name: string | null;
  route_type: number;
  trip_headsign: string | null;
  departure_time: string;  // HH:MM:SS (may be >24h)
  service_id: string;
}

export async function getDepartures(
  env: Env,
  stopId: string,
  windowMinutes: number,
  limit: number,
): Promise<Departure[]> {
  const now = new Date();
  // GTFS times use the service day's noon as anchor — a service day extends
  // past midnight as e.g. 25:30:00. We look up today + yesterday's services
  // and filter by absolute timestamp.
  const today = serviceDate(now, 0);
  const yesterday = serviceDate(now, -1);
  const activeToday = await activeServiceIds(env, today);
  const activeYesterday = await activeServiceIds(env, yesterday);

  const horizonMs = windowMinutes * 60 * 1000;
  const nowMs = now.getTime();

  const rows = await fetchScheduledRows(env, stopId, [...activeToday, ...activeYesterday]);

  const tripUpdates = await getTripUpdates(env).catch(() => new Map());
  const yesterdayDate = offsetDate(now, -1);

  const out: Departure[] = [];
  const consider = (r: ScheduledRow, scheduledMs: number) => {
    if (scheduledMs < nowMs - 60_000) return;
    if (scheduledMs > nowMs + horizonMs) return;

    const tu = tripUpdates.get(r.trip_id);
    const isCancelled = tu?.schedule_relationship === 3;
    const stuMatch = tu?.stop_time_updates.find(s => s.stop_id === stopId);
    const delaySec = stuMatch?.departure_delay ?? stuMatch?.arrival_delay ?? null;

    out.push({
      trip_id: r.trip_id,
      route_id: r.route_id,
      route_short_name: r.route_short_name,
      route_long_name: r.route_long_name,
      route_type: r.route_type,
      headsign: r.trip_headsign,
      scheduled_departure: new Date(scheduledMs).toISOString(),
      predicted_departure: delaySec != null
        ? new Date(scheduledMs + delaySec * 1000).toISOString()
        : null,
      delay_seconds: delaySec,
      is_realtime: tu != null,
      is_cancelled: isCancelled,
    });
  };

  for (const r of rows) {
    // A service_id can be active on consecutive days, so each row may fire on
    // today (anchored at today's midnight) AND/OR as the tail of yesterday's
    // service day (only relevant when departure_time >= 24:00:00).
    if (activeToday.has(r.service_id)) {
      consider(r, applyGtfsTime(now, r.departure_time));
    }
    if (activeYesterday.has(r.service_id) && r.departure_time >= "24:00:00") {
      consider(r, applyGtfsTime(yesterdayDate, r.departure_time));
    }
  }

  out.sort((a, b) => {
    const at = a.predicted_departure ?? a.scheduled_departure;
    const bt = b.predicted_departure ?? b.scheduled_departure;
    return at.localeCompare(bt);
  });
  return out.slice(0, limit);
}

async function fetchScheduledRows(
  env: Env,
  stopId: string,
  serviceIds: string[],
): Promise<ScheduledRow[]> {
  if (serviceIds.length === 0) return [];
  const placeholders = serviceIds.map((_, i) => `?${i + 2}`).join(",");
  const { results } = await env.DB.prepare(
    `SELECT st.trip_id, t.route_id,
            r.route_short_name, r.route_long_name, r.route_type,
            t.trip_headsign, st.departure_time, t.service_id
     FROM stop_times st
     JOIN trips t ON t.trip_id = st.trip_id
     JOIN routes r ON r.route_id = t.route_id
     WHERE st.stop_id = ?1
       AND t.service_id IN (${placeholders})
       AND st.pickup_type != 1`
  ).bind(stopId, ...serviceIds).all<ScheduledRow>();
  return results ?? [];
}

async function activeServiceIds(env: Env, dateYYYYMMDD: string): Promise<Set<string>> {
  const dow = dayOfWeekColumn(dateYYYYMMDD);
  const { results: base } = await env.DB.prepare(
    `SELECT service_id FROM calendar
     WHERE start_date <= ?1 AND end_date >= ?1 AND ${dow} = 1`
  ).bind(dateYYYYMMDD).all<{ service_id: string }>();
  const { results: ex } = await env.DB.prepare(
    `SELECT service_id, exception_type FROM calendar_dates WHERE date = ?1`
  ).bind(dateYYYYMMDD).all<{ service_id: string; exception_type: number }>();

  const set = new Set((base ?? []).map(r => r.service_id));
  for (const e of ex ?? []) {
    if (e.exception_type === 1) set.add(e.service_id);
    if (e.exception_type === 2) set.delete(e.service_id);
  }
  return set;
}

function dayOfWeekColumn(yyyymmdd: string): string {
  const d = new Date(
    Number(yyyymmdd.slice(0, 4)),
    Number(yyyymmdd.slice(4, 6)) - 1,
    Number(yyyymmdd.slice(6, 8)),
  );
  return ["sunday","monday","tuesday","wednesday","thursday","friday","saturday"][d.getDay()];
}

const BRISBANE_DATE_FMT = new Intl.DateTimeFormat("en-CA", {
  timeZone: BRISBANE_TZ, year: "numeric", month: "2-digit", day: "2-digit",
});

// "YYYY-MM-DD" for the Brisbane-local calendar date of d.
function brisbaneDateISO(d: Date): string {
  return BRISBANE_DATE_FMT.format(d);
}

function serviceDate(now: Date, dayOffset: number): string {
  return brisbaneDateISO(offsetDate(now, dayOffset)).replaceAll("-", "");
}

function offsetDate(d: Date, dayOffset: number): Date {
  return new Date(d.getTime() + dayOffset * 86_400_000);
}

// UTC ms for "midnight Brisbane on the Brisbane-local calendar date of baseDate",
// plus the GTFS HH:MM:SS offset (which may exceed 24h for late-night trips).
// Brisbane has no DST so the +10:00 offset is constant.
function applyGtfsTime(baseDate: Date, hms: string): number {
  const [h, mn, s] = hms.split(":").map(Number);
  const totalSec = h * 3600 + mn * 60 + s;
  const midnightMs = Date.parse(`${brisbaneDateISO(baseDate)}T00:00:00+10:00`);
  return midnightMs + totalSec * 1000;
}
