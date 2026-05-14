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
}

interface SchoolRouteRow {
  route_short_name: string;
  route_long_name: string | null;
  route_type: number;
  trip_headsign: string;
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
  const { results } = await env.DB.prepare(
    `WITH school_trips AS (
       SELECT t.trip_id, t.trip_headsign,
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
     SELECT DISTINCT
       st.route_short_name, st.route_long_name, st.route_type,
       st.trip_headsign,
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

  // Group by (route_short_name, school_headsign), keep the closest stop.
  const grouped = new Map<string, SchoolRouteMatch>();
  for (const r of results) {
    const distance = haversineMeters(lat, lon, r.stop_lat, r.stop_lon);
    if (distance > radiusM) continue;
    const key = `${r.route_short_name}|${r.trip_headsign}`;
    const existing = grouped.get(key);
    if (!existing || distance < existing.nearest_stop.distance_m) {
      grouped.set(key, {
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
      });
    }
  }

  return Array.from(grouped.values())
    .sort((a, b) => a.nearest_stop.distance_m - b.nearest_stop.distance_m)
    .slice(0, limit);
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
// Direct-route journey planner.
// Find single-trip transit journeys whose board stop is within walking
// distance of `from` and alight stop within walking distance of `to`. No
// transfers (v1). Sorted by total journey time (walking + waiting + transit).
// -------------------------------------------------------------------------

const WALK_SPEED_M_PER_MIN = 80;  // ~5 km/h, typical urban walking pace

export interface JourneyOption {
  total_minutes: number;
  walk_to_minutes: number;
  transit_minutes: number;
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
  alight: JourneyStopRef;
  is_realtime: boolean;
  delay_seconds: number | null;
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
): Promise<JourneyOption[]> {
  const fromStops = await findNearbyStops(env, fromLat, fromLon, walkRadiusM, 15);
  const toStops   = await findNearbyStops(env, toLat,   toLon,   walkRadiusM, 15);
  if (fromStops.length === 0 || toStops.length === 0) return [];

  const now = new Date();
  const dateStr = brisbaneDateISO(now).replaceAll("-", "");
  const dowCol = dayOfWeekColumn(dateStr);

  // Brisbane-local HH:MM:SS for "now" and "now + window", used to push the
  // time-window filter down into SQL. GTFS times can exceed 24:00:00 for
  // late-night trips so the upper bound is allowed to exceed 23:59:59.
  const nowLocal = brisbaneClock(now);
  const upper = clockPlusMinutes(nowLocal, windowMinutes);

  // Param layout: ?1..?N = board stops, ?N+1..?N+M = alight stops,
  // then dateStr, nowLocal, upper.
  const boardPh = fromStops.map((_, i) => `?${i + 1}`).join(",");
  const alightOff = fromStops.length + 1;
  const alightPh = toStops.map((_, i) => `?${i + alightOff}`).join(",");
  const dateIdx = alightOff + toStops.length;
  const lowerIdx = dateIdx + 1;
  const upperIdx = dateIdx + 2;

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
    WHERE sa.stop_id IN (${boardPh})
      AND sb.stop_id IN (${alightPh})
      AND t.service_id IN (
        SELECT service_id FROM calendar
        WHERE start_date <= ?${dateIdx} AND end_date >= ?${dateIdx} AND ${dowCol} = 1
      )
      AND sa.departure_time BETWEEN ?${lowerIdx} AND ?${upperIdx}
      AND sa.pickup_type != 1
      AND sb.drop_off_type != 1
    ORDER BY sa.departure_time
    LIMIT 400
  `;
  const params = [
    ...fromStops.map(s => s.stop_id),
    ...toStops.map(s => s.stop_id),
    dateStr, nowLocal, upper,
  ];
  const { results } = await env.DB.prepare(sql).bind(...params).all<CandidateRow>();
  if (!results || results.length === 0) return [];

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

  // Dedupe: same route, headsign, board+alight stops — keep earliest trip.
  const seen = new Map<string, JourneyOption>();
  for (const c of candidates) {
    const key = `${c.route.route_id}|${c.headsign ?? ""}|${c.board.stop_id}|${c.alight.stop_id}`;
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
  // past midnight as e.g. 25:30:00. We look up today + yesterday's services
  // and filter by absolute timestamp.
  const today = serviceDate(now, 0);
  const yesterday = serviceDate(now, -1);
  const activeToday = await activeServiceIds(env, today);
  const activeYesterday = await activeServiceIds(env, yesterday);

  const horizonMs = windowMinutes * 60 * 1000;
  const nowMs = now.getTime();

  const rows = await fetchScheduledRows(env, stopIds, [...activeToday, ...activeYesterday]);

  const tripUpdates = await getTripUpdates(env).catch(() => new Map());
  const yesterdayDate = offsetDate(now, -1);

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
