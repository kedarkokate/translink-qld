import type { Env, Stop, StopWithDistance, Route, Departure } from "./types";
import { boundingBox, haversineMeters } from "./distance";
import { getTripUpdates } from "./gtfsRt";

const BRISBANE_TZ = "Australia/Brisbane";

export async function findNearbyStops(
  env: Env,
  lat: number, lon: number,
  radiusM: number, limit: number,
  consolidate: boolean = false,
): Promise<StopWithDistance[]> {
  const bbox = boundingBox(lat, lon, radiusM);
  // Bounding-box prefilter — keeps the scan ~O(stops in bbox), then we
  // compute Haversine and sort in code. ~12K SEQ stops total, so even a
  // generous bbox returns at most a few hundred rows.
  const { results } = await env.DB.prepare(
    `SELECT stop_id, stop_code, stop_name, stop_lat, stop_lon,
            location_type, parent_station, platform_code, route_types
     FROM stops
     WHERE stop_lat BETWEEN ?1 AND ?2
       AND stop_lon BETWEEN ?3 AND ?4
       AND location_type = 0`
  )
    .bind(bbox.minLat, bbox.maxLat, bbox.minLon, bbox.maxLon)
    .all<Stop>();

  const withDistance = (results ?? [])
    .map(s => ({
      ...s,
      distance_m: haversineMeters(lat, lon, s.stop_lat, s.stop_lon),
    }))
    .filter(s => s.distance_m <= radiusM);

  const collapsed = consolidate
    ? await consolidateRailStations(env, withDistance)
    : withDistance;

  return collapsed
    .sort((a, b) => a.distance_m - b.distance_m)
    .slice(0, limit);
}

/// Returns either [stopId] for a regular stop, or every child platform id
/// when stopId references a station (location_type=1). Used so endpoints
/// keyed by a station id transparently aggregate across all its platforms.
async function expandStopId(env: Env, stopId: string): Promise<string[]> {
  const { results } = await env.DB.prepare(
    `SELECT stop_id FROM stops WHERE stop_id = ?1 OR parent_station = ?1`
  ).bind(stopId).all<{ stop_id: string }>();
  const ids = (results ?? []).map(r => r.stop_id);
  return ids.length > 0 ? ids : [stopId];
}

/// For each rail platform (route_type 1 or 2) that has a parent_station,
/// replace the platform with its parent station record so the map shows
/// a single pin per station. Other modes pass through unchanged.
async function consolidateRailStations(
  env: Env, stops: StopWithDistance[],
): Promise<StopWithDistance[]> {
  const isRailType = (rt: string | null) => {
    const types = (rt ?? "").split(",");
    return types.includes("2") || types.includes("1");
  };

  const parentIds = [...new Set(
    stops
      .filter(s => s.parent_station && isRailType(s.route_types))
      .map(s => s.parent_station!),
  )];
  if (parentIds.length === 0) return stops;

  const ph = parentIds.map((_, i) => `?${i + 1}`).join(",");
  const { results } = await env.DB.prepare(
    `SELECT stop_id, stop_code, stop_name, stop_lat, stop_lon,
            location_type, parent_station, platform_code, route_types
     FROM stops WHERE stop_id IN (${ph})`
  ).bind(...parentIds).all<Stop>();
  const parentMap = new Map((results ?? []).map(p => [p.stop_id, p]));

  // Dedupe by station id; keep the nearest-platform distance and inherit
  // route_types from one of the platforms (parent stations don't carry it).
  const out = new Map<string, StopWithDistance>();
  for (const s of stops) {
    if (s.parent_station && isRailType(s.route_types) && parentMap.has(s.parent_station)) {
      const parent = parentMap.get(s.parent_station)!;
      const existing = out.get(parent.stop_id);
      const distance = existing ? Math.min(existing.distance_m, s.distance_m) : s.distance_m;
      out.set(parent.stop_id, {
        stop_id: parent.stop_id,
        stop_code: parent.stop_code,
        stop_name: parent.stop_name,
        stop_lat: parent.stop_lat,
        stop_lon: parent.stop_lon,
        location_type: parent.location_type,
        parent_station: parent.parent_station,
        platform_code: parent.platform_code,
        route_types: s.route_types,
        distance_m: distance,
      });
    } else {
      out.set(s.stop_id, s);
    }
  }
  return Array.from(out.values());
}

export async function searchStops(
  env: Env, query: string,
  near: { lat: number; lon: number } | null,
  limit: number,
): Promise<StopWithDistance[]> {
  const trimmed = query.trim();
  if (trimmed.length < 2) return [];

  // LIKE patterns: escape % _ \ so user input doesn't get treated as wildcard.
  const escaped = trimmed.replace(/[%_\\]/g, "\\$&");
  const namePattern = `%${escaped}%`;
  const codePattern = `%${escaped}%`;

  const { results } = await env.DB.prepare(
    `SELECT stop_id, stop_code, stop_name, stop_lat, stop_lon,
            location_type, parent_station, platform_code, route_types
     FROM stops
     WHERE location_type = 0
       AND (stop_name LIKE ?1 ESCAPE '\\' COLLATE NOCASE
            OR stop_code LIKE ?2 ESCAPE '\\')
     LIMIT 200`
  ).bind(namePattern, codePattern).all<Stop>();

  if (!results || results.length === 0) return [];

  // Attach distances first so consolidateRailStations can keep the
  // closest-platform distance when it collapses platforms into a parent.
  const withDistance: StopWithDistance[] = results.map(s => ({
    ...s,
    distance_m: near
      ? haversineMeters(near.lat, near.lon, s.stop_lat, s.stop_lon)
      : Number.MAX_VALUE,
  }));

  // Collapse train station platforms into one entry per station so search
  // results show "Central station" once instead of every platform.
  const collapsed = await consolidateRailStations(env, withDistance);

  const qLower = trimmed.toLowerCase();
  type Scored = StopWithDistance & { _score: number };
  const scored: Scored[] = collapsed.map(s => {
    const nameLower = s.stop_name.toLowerCase();
    let score: number;
    if (s.stop_code === trimmed) score = 100;
    else if (s.stop_code?.endsWith(trimmed)) score = 80;       // matches "1013" → "001013"
    else if (s.stop_code?.startsWith(trimmed)) score = 70;
    else if (nameLower === qLower) score = 60;
    else if (nameLower.startsWith(qLower)) score = 40;
    else if (nameLower.includes(qLower)) score = 20;
    else score = 10;
    return { ...s, _score: score };
  });

  scored.sort((a, b) => {
    if (b._score !== a._score) return b._score - a._score;
    return a.distance_m - b.distance_m;
  });

  return scored.slice(0, limit).map(({ _score, ...rest }) => rest);
}

export async function getStop(env: Env, stopId: string): Promise<Stop | null> {
  return env.DB.prepare(
    `SELECT stop_id, stop_code, stop_name, stop_lat, stop_lon,
            location_type, parent_station, platform_code, route_types
     FROM stops WHERE stop_id = ?1`
  ).bind(stopId).first<Stop>();
}

export async function getRoutesForStop(env: Env, stopId: string): Promise<Route[]> {
  const stopIds = await expandStopId(env, stopId);
  const ph = stopIds.map((_, i) => `?${i + 1}`).join(",");
  // GROUP BY route_short_name so each user-visible route appears once even
  // when TransLink has many route_id variants for the same short_name.
  // SQLite picks an arbitrary value for the non-aggregated columns, which
  // is fine because variants share the human-meaningful fields.
  const { results } = await env.DB.prepare(
    `SELECT MIN(r.route_id) AS route_id, r.route_short_name,
            r.route_long_name, r.route_type, r.route_color, r.route_text_color
     FROM routes r
     JOIN trips t ON t.route_id = r.route_id
     JOIN stop_times st ON st.trip_id = t.trip_id
     WHERE st.stop_id IN (${ph})
     GROUP BY r.route_short_name
     ORDER BY r.route_short_name`
  ).bind(...stopIds).all<Route>();
  return results ?? [];
}

export interface RouteStopsResult {
  route_short_name: string;
  route_long_name: string | null;
  route_type: number;
  route_color: string | null;
  route_text_color: string | null;
  directions: RouteDirection[];
}

export interface RouteDirection {
  direction_id: number | null;
  headsign: string | null;
  stops: Array<Stop & { stop_sequence: number }>;
}

export async function getStopsForRoute(
  env: Env, shortName: string,
): Promise<RouteStopsResult | null> {
  // One representative route record for naming + type metadata.
  const meta = await env.DB.prepare(
    `SELECT route_short_name, route_long_name, route_type,
            route_color, route_text_color
     FROM routes WHERE route_short_name = ?1 COLLATE NOCASE LIMIT 1`
  ).bind(shortName).first<{
    route_short_name: string;
    route_long_name: string | null;
    route_type: number;
    route_color: string | null;
    route_text_color: string | null;
  }>();
  if (!meta) return null;

  // Pull every (direction_id, trip_headsign) pair across all matching route
  // variants and a representative trip_id for each (the one with the most
  // stop_times — usually the canonical, non-express variant).
  type Row = {
    direction_id: number | null;
    trip_headsign: string | null;
    stop_id: string;
    stop_code: string | null;
    stop_name: string;
    stop_lat: number;
    stop_lon: number;
    location_type: number;
    parent_station: string | null;
    platform_code: string | null;
    route_types: string | null;
    stop_sequence: number;
  };

  const { results } = await env.DB.prepare(
    `WITH route_match AS (
       SELECT route_id FROM routes WHERE route_short_name = ?1 COLLATE NOCASE
     ),
     trip_lengths AS (
       SELECT t.trip_id, t.direction_id, t.trip_headsign,
              COUNT(st.stop_id) AS n
       FROM trips t
       JOIN route_match rm ON rm.route_id = t.route_id
       JOIN stop_times st ON st.trip_id = t.trip_id
       GROUP BY t.trip_id
     ),
     ranked AS (
       SELECT trip_id, direction_id, trip_headsign,
              ROW_NUMBER() OVER (
                PARTITION BY COALESCE(direction_id, -1), COALESCE(trip_headsign, '')
                ORDER BY n DESC, trip_id
              ) AS rn
       FROM trip_lengths
     ),
     rep AS (
       SELECT trip_id, direction_id, trip_headsign FROM ranked WHERE rn = 1
     )
     SELECT rep.direction_id, rep.trip_headsign,
            s.stop_id, s.stop_code, s.stop_name, s.stop_lat, s.stop_lon,
            s.location_type, s.parent_station, s.platform_code, s.route_types,
            st.stop_sequence
     FROM rep
     JOIN stop_times st ON st.trip_id = rep.trip_id
     JOIN stops s ON s.stop_id = st.stop_id
     ORDER BY rep.trip_headsign, st.stop_sequence`
  ).bind(shortName).all<Row>();

  if (!results || results.length === 0) return null;

  const byKey = new Map<string, RouteDirection>();
  for (const r of results) {
    const key = `${r.direction_id ?? -1}|${r.trip_headsign ?? ""}`;
    if (!byKey.has(key)) {
      byKey.set(key, {
        direction_id: r.direction_id,
        headsign: r.trip_headsign,
        stops: [],
      });
    }
    byKey.get(key)!.stops.push({
      stop_id: r.stop_id,
      stop_code: r.stop_code,
      stop_name: r.stop_name,
      stop_lat: r.stop_lat,
      stop_lon: r.stop_lon,
      location_type: r.location_type,
      parent_station: r.parent_station,
      platform_code: r.platform_code,
      route_types: r.route_types,
      stop_sequence: r.stop_sequence,
    });
  }

  return {
    route_short_name: meta.route_short_name,
    route_long_name: meta.route_long_name,
    route_type: meta.route_type,
    route_color: meta.route_color,
    route_text_color: meta.route_text_color,
    directions: Array.from(byKey.values()),
  };
}

// -------------------------------------------------------------------------
// School routes near a location.
// TransLink doesn't tag school services at the route level — instead it
// creates per-school trip variants on regular bus routes, with the school's
// name as the trip_headsign (e.g. "Stuartholme College", "Carina State
// School"). The match below is a heuristic on that headsign.
// -------------------------------------------------------------------------

export interface SchoolRouteMatch {
  route_short_name: string;
  route_long_name: string | null;
  route_type: number;
  school_headsign: string;
  nearest_stop: StopWithDistance;
  /// ISO timestamp of the next scheduled departure of this route/headsign
  /// from `nearest_stop`, looking forward up to 7 days. Null when no
  /// service is running in that window (long school holiday, route
  /// suspended, etc.).
  next_departure: string | null;
}

interface SchoolRouteRow {
  route_short_name: string;
  route_long_name: string | null;
  route_type: number;
  trip_headsign: string;
  trip_id: string;
  departure_time: string;
  service_id: string;
  stop_id: string;
  stop_code: string | null;
  stop_name: string;
  stop_lat: number;
  stop_lon: number;
  location_type: number;
  parent_station: string | null;
  platform_code: string | null;
  route_types: string | null;
}

export async function findSchoolRoutesNear(
  env: Env, lat: number, lon: number,
  radiusM: number, limit: number,
): Promise<SchoolRouteMatch[]> {
  const bbox = boundingBox(lat, lon, radiusM);
  // The patterns target headsigns that name an actual school/college rather
  // than street addresses like "Suburb, College Ave" or "X, School Rd".
  // Includes stop_times + service_id so we can compute "next departure"
  // per (route, headsign, stop) in JS without a second round-trip to D1.
  const { results } = await env.DB.prepare(
    `WITH school_trips AS (
       SELECT t.trip_id, t.trip_headsign, t.service_id,
              r.route_short_name, r.route_long_name, r.route_type
       FROM trips t
       JOIN routes r ON r.route_id = t.route_id
       WHERE t.trip_headsign LIKE '%School' COLLATE NOCASE
          OR t.trip_headsign LIKE '%College' COLLATE NOCASE
          OR t.trip_headsign LIKE '%Grammar' COLLATE NOCASE
          OR t.trip_headsign LIKE '%Academy' COLLATE NOCASE
          OR t.trip_headsign LIKE '%School,%' COLLATE NOCASE
          OR t.trip_headsign LIKE '%College,%' COLLATE NOCASE
          OR LOWER(t.trip_headsign) LIKE '%state school%'
          OR LOWER(t.trip_headsign) LIKE '%state high%'
     )
     SELECT
       st.route_short_name, st.route_long_name, st.route_type,
       st.trip_headsign, st.trip_id, st.service_id,
       stm.departure_time,
       s.stop_id, s.stop_code, s.stop_name, s.stop_lat, s.stop_lon,
       s.location_type, s.parent_station, s.platform_code, s.route_types
     FROM school_trips st
     JOIN stop_times stm ON stm.trip_id = st.trip_id
     JOIN stops s ON s.stop_id = stm.stop_id
     WHERE s.stop_lat BETWEEN ?1 AND ?2
       AND s.stop_lon BETWEEN ?3 AND ?4
       AND s.location_type = 0`
  ).bind(bbox.minLat, bbox.maxLat, bbox.minLon, bbox.maxLon).all<SchoolRouteRow>();

  if (!results || results.length === 0) return [];

  // Pre-fetch the 7-day calendar slice: for each of today + next 6 days,
  // which service_ids are active. This is cheap (one query, ≤ a few
  // hundred rows for a single week's services) and lets us answer
  // "when is the next school bus" without falling out of school terms.
  const now = new Date();
  const activeByDate = await fetchActiveServicesNext7Days(env, now);

  // Group by (route_short_name, school_headsign), keep the closest stop.
  // For each group, collect every (stop_time, service_id) candidate at
  // that stop so we can pick the earliest valid departure afterwards.
  interface Candidate {
    departure_time: string;
    service_id: string;
    stop_id: string;
  }
  interface AccumulatedMatch {
    match: SchoolRouteMatch;
    candidates: Candidate[];
  }
  const grouped = new Map<string, AccumulatedMatch>();

  for (const r of results) {
    const distance = haversineMeters(lat, lon, r.stop_lat, r.stop_lon);
    if (distance > radiusM) continue;
    const key = `${r.route_short_name}|${r.trip_headsign}`;
    let entry = grouped.get(key);
    if (!entry) {
      entry = {
        match: {
          route_short_name: r.route_short_name,
          route_long_name: r.route_long_name,
          route_type: r.route_type,
          school_headsign: r.trip_headsign,
          nearest_stop: {
            stop_id: r.stop_id, stop_code: r.stop_code, stop_name: r.stop_name,
            stop_lat: r.stop_lat, stop_lon: r.stop_lon,
            location_type: r.location_type, parent_station: r.parent_station,
            platform_code: r.platform_code, route_types: r.route_types,
            distance_m: distance,
          },
          next_departure: null,
        },
        candidates: [],
      };
      grouped.set(key, entry);
    } else if (distance < entry.match.nearest_stop.distance_m) {
      // Found a closer stop for this (route, headsign) — swap. Drop
      // candidates from the previous (farther) stop; we'll only count
      // departures from the closest one.
      entry.match.nearest_stop = {
        stop_id: r.stop_id, stop_code: r.stop_code, stop_name: r.stop_name,
        stop_lat: r.stop_lat, stop_lon: r.stop_lon,
        location_type: r.location_type, parent_station: r.parent_station,
        platform_code: r.platform_code, route_types: r.route_types,
        distance_m: distance,
      };
      entry.candidates = entry.candidates.filter(c => c.stop_id === r.stop_id);
    }
    if (r.stop_id === entry.match.nearest_stop.stop_id) {
      entry.candidates.push({
        departure_time: r.departure_time,
        service_id: r.service_id,
        stop_id: r.stop_id,
      });
    }
  }

  // For each match, look forward up to 7 days and pick the earliest
  // departure whose service_id is active on that date. Anchors GTFS
  // HH:MM:SS departure to the candidate date's midnight (GTFS allows
  // values past 24:00:00 for late-night trips); the first hit wins.
  const nowMs = now.getTime();
  for (const entry of grouped.values()) {
    let earliest: number | null = null;
    for (let dayOffset = 0; dayOffset < 7; dayOffset++) {
      const day = offsetDate(now, dayOffset);
      const dateStr = brisbaneDateISO(day).replaceAll("-", "");
      const active = activeByDate.get(dateStr) ?? new Set<string>();
      if (active.size === 0) continue;
      for (const c of entry.candidates) {
        if (!active.has(c.service_id)) continue;
        const candidateMs = applyGtfsTime(day, c.departure_time);
        if (candidateMs < nowMs - 60_000) continue;
        if (earliest === null || candidateMs < earliest) earliest = candidateMs;
      }
      if (earliest !== null) break;
    }
    if (earliest !== null) entry.match.next_departure = new Date(earliest).toISOString();
  }

  return Array.from(grouped.values())
    .map(e => e.match)
    .sort((a, b) => a.nearest_stop.distance_m - b.nearest_stop.distance_m)
    .slice(0, limit);
}

/// One query returning every service_id active on each of today and the
/// next 6 days. Result is a map from yyyymmdd → Set<service_id>. Used by
/// the school-route planner to answer "next departure" without doing
/// per-match SQL round-trips.
async function fetchActiveServicesNext7Days(
  env: Env, now: Date,
): Promise<Map<string, Set<string>>> {
  const out = new Map<string, Set<string>>();
  const dates: { dateStr: string; dowCol: string }[] = [];
  for (let i = 0; i < 7; i++) {
    const day = offsetDate(now, i);
    dates.push({
      dateStr: brisbaneDateISO(day).replaceAll("-", ""),
      dowCol: dayOfWeekColumn(brisbaneDateISO(day).replaceAll("-", "")),
    });
  }
  // Build one query that ORs across all days; cheaper than 7 round-trips.
  // Bind ?1..?7 to the 7 dateStrings; each clause references its own slot.
  const clauses = dates.map((d, i) =>
    `(start_date <= ?${i + 1} AND end_date >= ?${i + 1} AND ${d.dowCol} = 1)`
  );
  const sql = `SELECT service_id, start_date, end_date,
                      monday, tuesday, wednesday, thursday, friday, saturday, sunday
               FROM calendar
               WHERE ${clauses.join(" OR ")}`;
  const { results } = await env.DB.prepare(sql).bind(...dates.map(d => d.dateStr)).all<{
    service_id: string;
    start_date: string; end_date: string;
    monday: number; tuesday: number; wednesday: number;
    thursday: number; friday: number; saturday: number; sunday: number;
  }>();
  for (const d of dates) out.set(d.dateStr, new Set<string>());
  for (const row of results ?? []) {
    for (const d of dates) {
      if (row.start_date > d.dateStr || row.end_date < d.dateStr) continue;
      const dow = dayOfWeekFlag(row, d.dowCol);
      if (dow === 1) out.get(d.dateStr)?.add(row.service_id);
    }
  }
  return out;
}

function dayOfWeekFlag(
  row: { monday: number; tuesday: number; wednesday: number;
         thursday: number; friday: number; saturday: number; sunday: number },
  col: string,
): number {
  switch (col) {
    case "monday":    return row.monday;
    case "tuesday":   return row.tuesday;
    case "wednesday": return row.wednesday;
    case "thursday":  return row.thursday;
    case "friday":    return row.friday;
    case "saturday":  return row.saturday;
    case "sunday":    return row.sunday;
    default:          return 0;
  }
}

export async function findNearestStopForRoute(
  env: Env, shortName: string,
  userLat: number, userLon: number,
): Promise<{
  route_short_name: string;
  route_ids: string[];
  nearest_stop: StopWithDistance;
} | null> {
  const { results: stops } = await env.DB.prepare(
    `SELECT DISTINCT s.stop_id, s.stop_code, s.stop_name,
            s.stop_lat, s.stop_lon, s.location_type,
            s.parent_station, s.platform_code, s.route_types
     FROM stops s
     JOIN stop_times st ON st.stop_id = s.stop_id
     JOIN trips t ON t.trip_id = st.trip_id
     JOIN routes r ON r.route_id = t.route_id
     WHERE r.route_short_name = ?1 COLLATE NOCASE
       AND s.location_type = 0`
  ).bind(shortName).all<Stop>();

  if (!stops || stops.length === 0) return null;

  let nearest: StopWithDistance | null = null;
  for (const s of stops) {
    const d = haversineMeters(userLat, userLon, s.stop_lat, s.stop_lon);
    if (!nearest || d < nearest.distance_m) nearest = { ...s, distance_m: d };
  }

  const { results: routes } = await env.DB.prepare(
    `SELECT route_id FROM routes WHERE route_short_name = ?1 COLLATE NOCASE`
  ).bind(shortName).all<{ route_id: string }>();

  return {
    route_short_name: shortName,
    route_ids: (routes ?? []).map(r => r.route_id),
    nearest_stop: nearest!,
  };
}

// -------------------------------------------------------------------------
// Journey planner.
//
// Two algorithms:
//   1. Direct: a single trip whose board stop is within walking distance
//      of `from` and alight stop within walking distance of `to`.
//   2. One-transfer (opt-in via `withTransfers`): board near `from`, ride
//      to one of TRANSIT_HUBS, get off, board another trip at the same hub
//      (same `parent_station`), ride to a stop near `to`. Hubs are the top
//      ~25 interchange stations in SEQ by distinct-route count.
//
// Results are merged and sorted by total minutes (walk + wait + transit).
// -------------------------------------------------------------------------

const WALK_SPEED_M_PER_MIN = 80;  // ~5 km/h, typical urban walking pace
const MIN_TRANSFER_MINUTES = 3;   // cross-platform wait at a hub
const MAX_TRANSFER_MINUTES = 30;  // beyond this, two trips with a transfer

/// SEQ transit hubs (parent_stations) used as transfer anchors. Combines
/// the top train stations *and* the major busways: real Brisbane transfers
/// frequently happen at busways (Cultural Centre, King George Square,
/// Mt Gravatt, Carindale) rather than train platforms. Identified from D1
/// with `COUNT(DISTINCT route_id) GROUP BY parent_station`, separately for
/// all modes and for bus-only (route_type=3). Each entry is a
/// `parent_station` id; child platform stop_ids are resolved at query
/// time via the stops table.
const TRANSIT_HUBS: readonly string[] = [
  // ---- Train stations (rail) ----
  "place_bowsta",  // Bowen Hills station
  "place_romsta",  // Roma Street station
  "place_forsta",  // Fortitude Valley station
  "place_censta",  // Central station
  "place_egjsta",  // Eagle Junction station
  "place_norsta",  // Northgate station
  "place_petsta",  // Petrie station
  "place_parsta",  // Park Road / Boggo Road station
  "place_twgsta",  // Toowong station
  "place_indsta",  // Indooroopilly station
  "place_shesta",  // Sherwood station
  "place_milsta",  // Milton station
  "place_darsta",  // Darra station
  "place_oxlsta",  // Oxley station
  "place_corsta",  // Corinda station
  "place_albsta",  // Albion station
  "place_wolsta",  // Wooloowin station
  "place_sousta",  // South Brisbane station
  "place_sbasta",  // South Bank station (train)
  "place_beesta",  // Beenleigh station
  "place_logsta",  // Loganlea station
  "place_cabstn",  // Caboolture station
  "place_ipssta",  // Ipswich station
  "place_spcsta",  // Springfield Central station
  // ---- Busways + bus interchanges ----
  "place_burbs",   // Buranda busway station
  "place_grunbs",  // Griffith University station
  "place_ccbs",    // Cultural Centre busway station
  "place_rompl",   // Roma Street busway station
  "place_upmgbs",  // Upper Mt Gravatt station
  "place_sbank",   // South Bank busway station
  "place_mater",   // Mater Hill busway station
  "place_empbs",   // Eight Mile Plains station
  "place_wogba",   // Woolloongabba busway station
  "place_intind",  // Indooroopilly Shopping Centre interchange
  "place_rbwhp",   // RBWH busway station
  "place_intcar",  // Carindale Shopping Centre interchange
  "place_qsbs",    // Queen Street bus station
  "place_intgcy",  // Garden City Shopping Centre interchange
  "place_inttbl",  // Toombul Shopping Centre interchange
  "place_sprbst",  // Springwood station
  "place_grebs",   // Greenslopes busway station
  "place_pahste",  // PA Hospital busway station
  "place_qukgbs",  // QUT Kelvin Grove station
  "place_rchbs",   // Herston busway station
  "place_namsta",  // Nambour station
  "place_brsstn",  // Broadbeach South station (Gold Coast G:link)
];

export interface JourneyOption {
  total_minutes: number;
  walk_to_minutes: number;
  transit_minutes: number;       // sum of both legs' on-vehicle minutes
  walk_from_minutes: number;
  route: {
    route_id: string;
    route_short_name: string | null;
    route_long_name: string | null;
    route_type: number;
    route_color: string | null;
    route_text_color: string | null;
  };
  trip_id: string;
  headsign: string | null;
  board: JourneyStopRef;
  alight: JourneyStopRef;       // for transfer journeys, the hub stop
  is_realtime: boolean;
  delay_seconds: number | null;
  /// Only set on one-transfer journeys. When present, the user gets off at
  /// `alight` (the hub) and boards `transfer.route` at the same hub to ride
  /// to `transfer.alight` (the final destination near `to`).
  transfer?: JourneyTransferLeg;
}

interface JourneyTransferLeg {
  wait_minutes: number;
  route: {
    route_id: string;
    route_short_name: string | null;
    route_long_name: string | null;
    route_type: number;
    route_color: string | null;
    route_text_color: string | null;
  };
  trip_id: string;
  headsign: string | null;
  board: JourneyStopRef;
  alight: JourneyStopRef;
}

interface JourneyStopRef {
  stop_id: string;
  stop_name: string;
  stop_lat: number;
  stop_lon: number;
  walk_distance_m: number;
  scheduled_time: string;
  predicted_time: string | null;
}

interface CandidateRow {
  trip_id: string;
  board_stop: string; board_time: string;
  alight_stop: string; alight_time: string;
  route_id: string; trip_headsign: string | null;
  route_short_name: string | null; route_long_name: string | null;
  route_type: number;
  route_color: string | null; route_text_color: string | null;
}

export async function planJourney(
  env: Env,
  fromLat: number, fromLon: number,
  toLat: number, toLon: number,
  windowMinutes: number,
  walkRadiusM: number,
  maxResults: number,
  withTransfers: boolean = false,
): Promise<JourneyOption[]> {
  // Up to 80 nearby stops on each side. In dense CBD destinations there can
  // be 50+ platforms within a small radius (Queen Street has 30+ alone), so
  // the previous cap of 40 dropped popular alighting platforms (e.g.
  // Adelaide St stop 22 for route 411 from St Lucia) just outside the
  // candidate set even though they were well within the 800 m walk radius.
  // To stay under D1's 100-bound-parameter cap we inline both stop-id
  // lists as SQL literals — they come from D1, are trusted, and need no
  // parameter binding.
  const fromStops = await findNearbyStops(env, fromLat, fromLon, walkRadiusM, 80);
  const toStops   = await findNearbyStops(env, toLat,   toLon,   walkRadiusM, 80);
  if (fromStops.length === 0 || toStops.length === 0) return [];

  const now = new Date();
  const dateStr = brisbaneDateISO(now).replaceAll("-", "");
  const dowCol = dayOfWeekColumn(dateStr);

  // Brisbane-local HH:MM:SS for "now" and "now + window", used to push the
  // time-window filter down into SQL. GTFS times can exceed 24:00:00 for
  // late-night trips so the upper bound is allowed to exceed 23:59:59.
  const nowLocal = brisbaneClock(now);
  const upper = clockPlusMinutes(nowLocal, windowMinutes);

  const boardLiteral = fromStops.map(s => `'${s.stop_id.replace(/'/g, "''")}'`).join(",");
  const alightLiteral = toStops.map(s => `'${s.stop_id.replace(/'/g, "''")}'`).join(",");

  // Service-id filter is pushed into a subquery so we don't burn placeholders
  // on the dozens of services active each day. v1 uses calendar only (no
  // calendar_dates exceptions).
  const sql = `
    SELECT
      sa.trip_id,
      sa.stop_id AS board_stop, sa.departure_time AS board_time,
      sb.stop_id AS alight_stop, sb.arrival_time AS alight_time,
      t.route_id, t.trip_headsign,
      r.route_short_name, r.route_long_name, r.route_type,
      r.route_color, r.route_text_color
    FROM stop_times sa
    JOIN stop_times sb
      ON sb.trip_id = sa.trip_id AND sb.stop_sequence > sa.stop_sequence
    JOIN trips t ON t.trip_id = sa.trip_id
    JOIN routes r ON r.route_id = t.route_id
    WHERE sa.stop_id IN (${boardLiteral})
      AND sb.stop_id IN (${alightLiteral})
      AND t.service_id IN (
        SELECT service_id FROM calendar
        WHERE start_date <= ?1 AND end_date >= ?1 AND ${dowCol} = 1
      )
      AND sa.departure_time BETWEEN ?2 AND ?3
      AND sa.pickup_type != 1
      AND sb.drop_off_type != 1
    ORDER BY sa.departure_time
    LIMIT 400
  `;
  const { results } = await env.DB.prepare(sql).bind(dateStr, nowLocal, upper).all<CandidateRow>();
  if (!results || results.length === 0) {
    // No direct trips found. Don't return early when transfers are enabled —
    // a journey via a hub may still exist (e.g. Indooroopilly → Carindale,
    // where no single bus connects but bus → CBD hub → bus does).
    if (withTransfers) {
      return await planTransferJourneys(
        env, fromLat, fromLon, toLat, toLon,
        windowMinutes, walkRadiusM, maxResults,
      );
    }
    return [];
  }

  const tripUpdates = await getTripUpdates(env).catch(() => new Map());
  const nowMs = now.getTime();
  const windowMs = windowMinutes * 60_000;
  const fromMap = new Map(fromStops.map(s => [s.stop_id, s]));
  const toMap   = new Map(toStops.map(s => [s.stop_id, s]));

  const candidates: JourneyOption[] = [];
  for (const r of results) {
    const boardMs = applyGtfsTime(now, r.board_time);
    const alightMs = applyGtfsTime(now, r.alight_time);
    if (boardMs < nowMs - 60_000) continue;            // already gone
    if (boardMs > nowMs + windowMs) continue;          // beyond window
    if (alightMs <= boardMs) continue;                 // sanity guard

    const tu = tripUpdates.get(r.trip_id);
    if (tu?.schedule_relationship === 3) continue;     // cancelled trip
    const stu = tu?.stop_time_updates.find(s => s.stop_id === r.board_stop);
    const delaySec = stu?.departure_delay ?? stu?.arrival_delay ?? null;

    const predictedBoardMs = delaySec != null ? boardMs + delaySec * 1000 : boardMs;
    const predictedAlightMs = delaySec != null ? alightMs + delaySec * 1000 : alightMs;

    const boardStop = fromMap.get(r.board_stop)!;
    const alightStop = toMap.get(r.alight_stop)!;
    const walkToMin = boardStop.distance_m / WALK_SPEED_M_PER_MIN;
    const walkFromMin = alightStop.distance_m / WALK_SPEED_M_PER_MIN;
    const transitMin = (alightMs - boardMs) / 60_000;
    if (transitMin < 1) continue;                       // ignore micro-rides

    // Reject trips you couldn't physically reach walking
    const minutesUntilBoard = (predictedBoardMs - nowMs) / 60_000;
    if (minutesUntilBoard < walkToMin - 1) continue;

    const totalMin = (predictedAlightMs - nowMs) / 60_000 + walkFromMin;

    candidates.push({
      total_minutes: Math.round(totalMin),
      walk_to_minutes: Math.round(walkToMin),
      transit_minutes: Math.round(transitMin),
      walk_from_minutes: Math.round(walkFromMin),
      route: {
        route_id: r.route_id,
        route_short_name: r.route_short_name,
        route_long_name: r.route_long_name,
        route_type: r.route_type,
        route_color: r.route_color,
        route_text_color: r.route_text_color,
      },
      trip_id: r.trip_id,
      headsign: r.trip_headsign,
      board: {
        stop_id: boardStop.stop_id, stop_name: boardStop.stop_name,
        stop_lat: boardStop.stop_lat, stop_lon: boardStop.stop_lon,
        walk_distance_m: Math.round(boardStop.distance_m),
        scheduled_time: new Date(boardMs).toISOString(),
        predicted_time: delaySec != null ? new Date(predictedBoardMs).toISOString() : null,
      },
      alight: {
        stop_id: alightStop.stop_id, stop_name: alightStop.stop_name,
        stop_lat: alightStop.stop_lat, stop_lon: alightStop.stop_lon,
        walk_distance_m: Math.round(alightStop.distance_m),
        scheduled_time: new Date(alightMs).toISOString(),
        predicted_time: delaySec != null ? new Date(predictedAlightMs).toISOString() : null,
      },
      is_realtime: tu != null,
      delay_seconds: delaySec,
    });
  }

  // Dedupe by (route + headsign): show one "Catch route X to direction Y"
  // option per direction, picking the variant with the shortest total time.
  // The wider candidate set (80 nearby stops) tends to produce 5-10 rows for
  // the same route+headsign, varying only in which Hawken Dr or Adelaide St
  // platform they use — same bus, same trip, slightly different walks. The
  // user just wants one row per real option.
  const seen = new Map<string, JourneyOption>();
  for (const c of candidates) {
    const key = `${c.route.route_id}|${c.headsign ?? ""}`;
    const existing = seen.get(key);
    if (!existing || c.total_minutes < existing.total_minutes) seen.set(key, c);
  }

  let allOptions = Array.from(seen.values());

  // If the client opted in, also try hub-anchored one-transfer journeys and
  // merge them with the direct options. Sort score adds a transfer penalty
  // so a transfer route only beats a direct one when it's *significantly*
  // faster — matches user intuition (transfers have hidden cost: missed
  // connections, anxiety, real-world delays) and standard transit-app UX.
  if (withTransfers) {
    const transferOptions = await planTransferJourneys(
      env, fromLat, fromLon, toLat, toLon,
      windowMinutes, walkRadiusM, maxResults,
    );
    allOptions = allOptions.concat(transferOptions);
  }

  return allOptions
    .sort((a, b) => scoreOption(a) - scoreOption(b))
    .slice(0, maxResults);
}

/// Penalty added to a transfer journey's total minutes for sorting. A
/// direct 58-min ride should beat a transfer 50-min ride; a transfer that
/// saves 12+ min over the next direct still wins. Display total_minutes
/// stays accurate — only the sort score is biased.
const TRANSFER_PENALTY_MINUTES = 10;

function scoreOption(o: JourneyOption): number {
  return o.total_minutes + (o.transfer ? TRANSFER_PENALTY_MINUTES : 0);
}

interface HubPlatform {
  stop_id: string;
  parent_station: string;
  stop_name: string;
  stop_lat: number;
  stop_lon: number;
}

interface TransferLegRow {
  trip_id: string;
  board_stop: string;
  board_time: string;
  alight_stop: string;
  alight_time: string;
  route_id: string;
  trip_headsign: string | null;
  route_short_name: string | null;
  route_long_name: string | null;
  route_type: number;
  route_color: string | null;
  route_text_color: string | null;
}

/**
 * Hub-anchored one-transfer journey planner.
 *
 * Two SQL queries: leg1 (any fromStop → any hub platform) and leg2 (any hub
 * platform → any toStop). Join them in JS where the alight-hub of leg1
 * shares a `parent_station` with the board-hub of leg2, and the leg2
 * departure is at least MIN_TRANSFER_MINUTES after the leg1 arrival.
 *
 * Trusted hub stop_ids are inlined as SQL literals so we don't blow past
 * D1's 100-bound-parameter cap (~120-180 hub platform IDs across the 25
 * hubs).
 */
async function planTransferJourneys(
  env: Env,
  fromLat: number, fromLon: number,
  toLat: number, toLon: number,
  windowMinutes: number,
  walkRadiusM: number,
  maxResults: number,
): Promise<JourneyOption[]> {
  // For transfer journeys we widen both the walk radius and the stop count:
  // many real destinations have residential bus stops in the strict 500 m
  // radius but the actual hub-served interchange (e.g. Carindale Shopping)
  // sits 600-800 m away. Widening lets the algorithm find a feasible leg-2
  // alight even when the user's geocoded coord isn't on top of a busway.
  const transferWalkM = Math.max(walkRadiusM, 800);
  // 80 nearby stops on each side, matching the direct planner. SQL-side
  // both lists are inlined as literals (trusted from D1) so we don't blow
  // past D1's 100-bound-parameter cap.
  const fromStops = await findNearbyStops(env, fromLat, fromLon, transferWalkM, 80);
  const toStops   = await findNearbyStops(env, toLat,   toLon,   transferWalkM, 80);
  if (fromStops.length === 0 || toStops.length === 0) return [];

  // Resolve hub parent_stations → their child platform stop_ids.
  const hubPh = TRANSIT_HUBS.map((_, i) => `?${i + 1}`).join(",");
  const hubRes = await env.DB.prepare(
    `SELECT stop_id, parent_station, stop_name, stop_lat, stop_lon
     FROM stops WHERE parent_station IN (${hubPh})`
  ).bind(...TRANSIT_HUBS).all<HubPlatform>();
  const hubPlatforms = hubRes.results ?? [];
  if (hubPlatforms.length === 0) return [];
  const hubByStop = new Map<string, HubPlatform>(
    hubPlatforms.map(p => [p.stop_id, p])
  );
  // Inline as SQL literals: stop_ids are from D1, trusted, no injection risk.
  const hubStopLiteral = hubPlatforms
    .map(p => `'${p.stop_id.replace(/'/g, "''")}'`)
    .join(",");

  const now = new Date();
  const dateStr = brisbaneDateISO(now).replaceAll("-", "");
  const dowCol = dayOfWeekColumn(dateStr);
  const nowLocal = brisbaneClock(now);
  const upper = clockPlusMinutes(nowLocal, windowMinutes);
  const upperLeg2 = clockPlusMinutes(nowLocal, windowMinutes + 30);

  const boardLiteral = fromStops.map(s => `'${s.stop_id.replace(/'/g, "''")}'`).join(",");
  const alightLiteral = toStops.map(s => `'${s.stop_id.replace(/'/g, "''")}'`).join(",");

  // ---- Leg 1: any fromStop → any hub platform ----
  const leg1Sql = `
    SELECT sa.trip_id,
      sa.stop_id AS board_stop, sa.departure_time AS board_time,
      sb.stop_id AS alight_stop, sb.arrival_time AS alight_time,
      t.route_id, t.trip_headsign,
      r.route_short_name, r.route_long_name, r.route_type,
      r.route_color, r.route_text_color
    FROM stop_times sa
    JOIN stop_times sb ON sb.trip_id = sa.trip_id AND sb.stop_sequence > sa.stop_sequence
    JOIN trips t ON t.trip_id = sa.trip_id
    JOIN routes r ON r.route_id = t.route_id
    WHERE sa.stop_id IN (${boardLiteral})
      AND sb.stop_id IN (${hubStopLiteral})
      AND t.service_id IN (
        SELECT service_id FROM calendar
        WHERE start_date <= ?1 AND end_date >= ?1 AND ${dowCol} = 1
      )
      AND sa.departure_time BETWEEN ?2 AND ?3
      AND sa.pickup_type != 1 AND sb.drop_off_type != 1
    ORDER BY sa.departure_time
    LIMIT 600
  `;
  const { results: leg1Rows = [] } = await env.DB.prepare(leg1Sql)
    .bind(dateStr, nowLocal, upper)
    .all<TransferLegRow>();

  // ---- Leg 2: any hub platform → any toStop ----
  const leg2Sql = `
    SELECT sa.trip_id,
      sa.stop_id AS board_stop, sa.departure_time AS board_time,
      sb.stop_id AS alight_stop, sb.arrival_time AS alight_time,
      t.route_id, t.trip_headsign,
      r.route_short_name, r.route_long_name, r.route_type,
      r.route_color, r.route_text_color
    FROM stop_times sa
    JOIN stop_times sb ON sb.trip_id = sa.trip_id AND sb.stop_sequence > sa.stop_sequence
    JOIN trips t ON t.trip_id = sa.trip_id
    JOIN routes r ON r.route_id = t.route_id
    WHERE sa.stop_id IN (${hubStopLiteral})
      AND sb.stop_id IN (${alightLiteral})
      AND t.service_id IN (
        SELECT service_id FROM calendar
        WHERE start_date <= ?1 AND end_date >= ?1 AND ${dowCol} = 1
      )
      AND sa.departure_time BETWEEN ?2 AND ?3
      AND sa.pickup_type != 1 AND sb.drop_off_type != 1
    ORDER BY sa.departure_time
    LIMIT 600
  `;
  const { results: leg2Rows = [] } = await env.DB.prepare(leg2Sql)
    .bind(dateStr, nowLocal, upperLeg2)
    .all<TransferLegRow>();

  if (!leg1Rows.length || !leg2Rows.length) return [];

  // Index leg2 by hub parent_station for fast pairing
  const leg2ByHub = new Map<string, TransferLegRow[]>();
  for (const r of leg2Rows) {
    const hub = hubByStop.get(r.board_stop);
    if (!hub) continue;
    const list = leg2ByHub.get(hub.parent_station) ?? [];
    list.push(r);
    leg2ByHub.set(hub.parent_station, list);
  }

  const tripUpdates = await getTripUpdates(env).catch(() => new Map());
  const nowMs = now.getTime();
  const fromMap = new Map(fromStops.map(s => [s.stop_id, s]));
  const toMap   = new Map(toStops.map(s => [s.stop_id, s]));

  const candidates: JourneyOption[] = [];

  for (const a of leg1Rows) {
    const aHub = hubByStop.get(a.alight_stop);
    if (!aHub) continue;
    const leg1Board = fromMap.get(a.board_stop);
    if (!leg1Board) continue;

    const leg1BoardMs = applyGtfsTime(now, a.board_time);
    const leg1AlightMs = applyGtfsTime(now, a.alight_time);
    if (leg1BoardMs < nowMs - 60_000) continue;
    if (leg1AlightMs <= leg1BoardMs) continue;

    const walkToMin = leg1Board.distance_m / WALK_SPEED_M_PER_MIN;
    const minutesUntilBoard = (leg1BoardMs - nowMs) / 60_000;
    if (minutesUntilBoard < walkToMin - 1) continue;

    // Realtime: apply delay to leg1 only. Realtime trip updates don't
    // typically include enough forward-look to predict leg2 reliably.
    const tu = tripUpdates.get(a.trip_id);
    if (tu?.schedule_relationship === 3) continue;
    const stu = tu?.stop_time_updates.find((s: { stop_id: string }) => s.stop_id === a.board_stop);
    const delaySec = stu?.departure_delay ?? stu?.arrival_delay ?? null;
    const predLeg1BoardMs = delaySec != null ? leg1BoardMs + delaySec * 1000 : leg1BoardMs;
    const predLeg1AlightMs = delaySec != null ? leg1AlightMs + delaySec * 1000 : leg1AlightMs;

    const leg2List = leg2ByHub.get(aHub.parent_station) ?? [];
    for (const b of leg2List) {
      if (a.trip_id === b.trip_id) continue;  // same trip — not a transfer

      const bHub = hubByStop.get(b.board_stop)!;
      const leg2BoardMs = applyGtfsTime(now, b.board_time);
      const leg2AlightMs = applyGtfsTime(now, b.alight_time);
      if (leg2AlightMs <= leg2BoardMs) continue;

      const transferMin = (leg2BoardMs - leg1AlightMs) / 60_000;
      if (transferMin < MIN_TRANSFER_MINUTES) continue;
      if (transferMin > MAX_TRANSFER_MINUTES) continue;

      const leg2Alight = toMap.get(b.alight_stop);
      if (!leg2Alight) continue;
      const walkFromMin = leg2Alight.distance_m / WALK_SPEED_M_PER_MIN;

      const transitMin = (leg1AlightMs - leg1BoardMs) / 60_000
        + (leg2AlightMs - leg2BoardMs) / 60_000;
      const totalMin =
        (predLeg1BoardMs - nowMs) / 60_000
        + (leg1AlightMs - leg1BoardMs) / 60_000
        + transferMin
        + (leg2AlightMs - leg2BoardMs) / 60_000
        + walkFromMin;
      if (totalMin > windowMinutes * 1.5) continue;

      candidates.push({
        total_minutes: Math.round(totalMin),
        walk_to_minutes: Math.round(walkToMin),
        transit_minutes: Math.round(transitMin),
        walk_from_minutes: Math.round(walkFromMin),
        route: {
          route_id: a.route_id,
          route_short_name: a.route_short_name,
          route_long_name: a.route_long_name,
          route_type: a.route_type,
          route_color: a.route_color,
          route_text_color: a.route_text_color,
        },
        trip_id: a.trip_id,
        headsign: a.trip_headsign,
        board: {
          stop_id: leg1Board.stop_id, stop_name: leg1Board.stop_name,
          stop_lat: leg1Board.stop_lat, stop_lon: leg1Board.stop_lon,
          walk_distance_m: Math.round(leg1Board.distance_m),
          scheduled_time: new Date(leg1BoardMs).toISOString(),
          predicted_time: delaySec != null ? new Date(predLeg1BoardMs).toISOString() : null,
        },
        alight: {
          stop_id: a.alight_stop, stop_name: aHub.stop_name,
          stop_lat: aHub.stop_lat, stop_lon: aHub.stop_lon,
          walk_distance_m: 0,
          scheduled_time: new Date(leg1AlightMs).toISOString(),
          predicted_time: delaySec != null ? new Date(predLeg1AlightMs).toISOString() : null,
        },
        is_realtime: tu != null,
        delay_seconds: delaySec,
        transfer: {
          wait_minutes: Math.round(transferMin),
          route: {
            route_id: b.route_id,
            route_short_name: b.route_short_name,
            route_long_name: b.route_long_name,
            route_type: b.route_type,
            route_color: b.route_color,
            route_text_color: b.route_text_color,
          },
          trip_id: b.trip_id,
          headsign: b.trip_headsign,
          board: {
            stop_id: b.board_stop, stop_name: bHub.stop_name,
            stop_lat: bHub.stop_lat, stop_lon: bHub.stop_lon,
            walk_distance_m: 0,
            scheduled_time: new Date(leg2BoardMs).toISOString(),
            predicted_time: null,
          },
          alight: {
            stop_id: leg2Alight.stop_id, stop_name: leg2Alight.stop_name,
            stop_lat: leg2Alight.stop_lat, stop_lon: leg2Alight.stop_lon,
            walk_distance_m: Math.round(leg2Alight.distance_m),
            scheduled_time: new Date(leg2AlightMs).toISOString(),
            predicted_time: null,
          },
        },
      });
    }
  }

  // Dedupe by (leg1 route + leg2 route) — show one "ride X, change to Y"
  // option per route-pair regardless of which specific board/alight
  // platforms it uses, keeping the variant with the shortest total time.
  // Matches the direct planner's collapsed dedup.
  const seen = new Map<string, JourneyOption>();
  for (const c of candidates) {
    const key = `${c.route.route_id}|${c.transfer!.route.route_id}`;
    const existing = seen.get(key);
    if (!existing || c.total_minutes < existing.total_minutes) seen.set(key, c);
  }
  return Array.from(seen.values())
    .sort((a, b) => a.total_minutes - b.total_minutes)
    .slice(0, maxResults);
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
  stop_id: string;
  route_id: string;
  route_short_name: string | null;
  route_long_name: string | null;
  route_type: number;
  route_color: string | null;
  route_text_color: string | null;
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
  const stopIds = await expandStopId(env, stopId);

  const now = new Date();
  // GTFS times use the service day's noon as anchor — a service day extends
  // past midnight as e.g. 25:30:00. We look up yesterday + today + tomorrow's
  // services and filter by absolute timestamp. Tomorrow matters because the
  // window_min can be up to 24h: when the caller asks for the "next service
  // up to 24h out" on a day with no service at this stop (e.g. Sunday at a
  // weekday-only bus stop), tomorrow's services are the only relevant set.
  const today = serviceDate(now, 0);
  const yesterday = serviceDate(now, -1);
  const tomorrow = serviceDate(now, 1);
  const activeToday = await activeServiceIds(env, today);
  const activeYesterday = await activeServiceIds(env, yesterday);
  const activeTomorrow = await activeServiceIds(env, tomorrow);

  const horizonMs = windowMinutes * 60 * 1000;
  const nowMs = now.getTime();

  const rows = await fetchScheduledRows(
    env, stopIds,
    [...activeToday, ...activeYesterday, ...activeTomorrow],
  );

  const tripUpdates = await getTripUpdates(env).catch(() => new Map());
  const yesterdayDate = offsetDate(now, -1);
  const tomorrowDate = offsetDate(now, 1);

  const out: Departure[] = [];
  const consider = (r: ScheduledRow, scheduledMs: number) => {
    if (scheduledMs < nowMs - 60_000) return;
    if (scheduledMs > nowMs + horizonMs) return;

    const tu = tripUpdates.get(r.trip_id);
    const isCancelled = tu?.schedule_relationship === 3;
    // Match the RT update against the specific platform stop the trip touches,
    // not the user's queried id (which may be a station aggregating many).
    const stuMatch = tu?.stop_time_updates.find(s => s.stop_id === r.stop_id);
    const delaySec = stuMatch?.departure_delay ?? stuMatch?.arrival_delay ?? null;

    out.push({
      trip_id: r.trip_id,
      route_id: r.route_id,
      route_short_name: r.route_short_name,
      route_long_name: r.route_long_name,
      route_type: r.route_type,
      route_color: r.route_color,
      route_text_color: r.route_text_color,
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
    // today (anchored at today's midnight), as the tail of yesterday's
    // service day (only when departure_time >= 24:00:00), and/or as
    // tomorrow's service when the window peeks past midnight. The `consider`
    // function filters out anything beyond `now + windowMs`, so loading all
    // three is safe even for short windows.
    if (activeToday.has(r.service_id)) {
      consider(r, applyGtfsTime(now, r.departure_time));
    }
    if (activeYesterday.has(r.service_id) && r.departure_time >= "24:00:00") {
      consider(r, applyGtfsTime(yesterdayDate, r.departure_time));
    }
    if (activeTomorrow.has(r.service_id)) {
      consider(r, applyGtfsTime(tomorrowDate, r.departure_time));
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
  stopIds: string[],
  serviceIds: string[],
): Promise<ScheduledRow[]> {
  if (stopIds.length === 0 || serviceIds.length === 0) return [];
  const stopPh = stopIds.map((_, i) => `?${i + 1}`).join(",");
  const serviceOff = stopIds.length + 1;
  const servicePh = serviceIds.map((_, i) => `?${i + serviceOff}`).join(",");
  const { results } = await env.DB.prepare(
    `SELECT st.trip_id, st.stop_id, t.route_id,
            r.route_short_name, r.route_long_name, r.route_type,
            r.route_color, r.route_text_color,
            t.trip_headsign, st.departure_time, t.service_id
     FROM stop_times st
     JOIN trips t ON t.trip_id = st.trip_id
     JOIN routes r ON r.route_id = t.route_id
     WHERE st.stop_id IN (${stopPh})
       AND t.service_id IN (${servicePh})
       AND st.pickup_type != 1`
  ).bind(...stopIds, ...serviceIds).all<ScheduledRow>();
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

const BRISBANE_CLOCK_FMT = new Intl.DateTimeFormat("en-GB", {
  timeZone: BRISBANE_TZ,
  hour: "2-digit", minute: "2-digit", second: "2-digit",
  hour12: false,
});

// "HH:MM:SS" for the Brisbane-local clock time of d (24-hour).
function brisbaneClock(d: Date): string {
  // en-GB returns "HH:MM:SS" but may use "24:00:00" at midnight in some
  // locales; normalize a hypothetical "24:..." to "00:...".
  const raw = BRISBANE_CLOCK_FMT.format(d);
  return raw.startsWith("24:") ? `00:${raw.slice(3)}` : raw;
}

// Adds N minutes to an "HH:MM:SS" string and may overflow past 24:00:00 to
// match GTFS's late-night convention (e.g. "25:30:00").
function clockPlusMinutes(hms: string, minutes: number): string {
  const [h, m, s] = hms.split(":").map(Number);
  const totalSec = h * 3600 + m * 60 + s + minutes * 60;
  const hh = Math.floor(totalSec / 3600);
  const mm = Math.floor((totalSec % 3600) / 60);
  const ss = totalSec % 60;
  return `${String(hh).padStart(2, "0")}:${String(mm).padStart(2, "0")}:${String(ss).padStart(2, "0")}`;
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
