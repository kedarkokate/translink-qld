import { Hono } from "hono";
import { cors } from "hono/cors";
import type { Env } from "./types";
import {
  findNearbyStops, getStop, getRoutesForStop,
  getRoute, getDepartures, findNearestStopForRoute, searchStops,
  planJourney, getStopsForRoute, findSchoolRoutesNear,
} from "./queries";
import { PRIVACY_HTML } from "./privacy";
import { SUPPORT_HTML } from "./support";

const app = new Hono<{ Bindings: Env }>();

app.use("*", cors({ origin: "*", maxAge: 600 }));

app.get("/privacy", c =>
  c.html(PRIVACY_HTML, 200, {
    "Cache-Control": "public, max-age=3600",
  }),
);

app.get("/support", c =>
  c.html(SUPPORT_HTML, 200, {
    "Cache-Control": "public, max-age=3600",
  }),
);

app.get("/v1/health", async c => {
  const meta = await c.env.DB.prepare(
    "SELECT key, value, updated_at FROM feed_meta WHERE key = 'last_ingest'",
  ).first<{ key: string; value: string; updated_at: number }>();
  return c.json({
    ok: true,
    last_ingest: meta?.value ?? null,
    last_ingest_unix: meta?.updated_at ?? null,
  });
});

app.get("/v1/stops/search", async c => {
  const q = c.req.query("q") ?? "";
  if (q.trim().length < 2) return c.json({ stops: [] });
  const lat = Number(c.req.query("lat"));
  const lon = Number(c.req.query("lon"));
  const near = (Number.isFinite(lat) && Number.isFinite(lon))
    ? { lat, lon } : null;
  const limit = Math.min(Number(c.req.query("limit") ?? 10), 25);
  return c.json({ stops: await searchStops(c.env, q, near, limit) });
});

app.get("/v1/stops/nearby", async c => {
  const lat = Number(c.req.query("lat"));
  const lon = Number(c.req.query("lon"));
  // 20 km cap — generous enough for a fully-zoomed-out SEQ view (iOS sends
  // up to ~21 km for the diagonal of a 15 km-radius square visible region).
  // The old 5 km cap caused train/ferry stations to silently vanish when
  // the map was zoomed out; the in-code Haversine filter still culls to
  // exactly the requested radius, and `limit` caps the response size.
  const radiusM = Math.min(Number(c.req.query("radius_m") ?? 500), 20_000);
  const limit = Math.min(Number(c.req.query("limit") ?? 25), 100);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    return c.json({ error: "lat and lon required" }, 400);
  }
  return c.json({
    stops: await findNearbyStops(c.env, lat, lon, radiusM, limit, true),
  });
});

app.get("/v1/stops/:stop_id", async c => {
  const stopId = c.req.param("stop_id");
  const stop = await getStop(c.env, stopId);
  if (!stop) return c.json({ error: "not found" }, 404);
  const routes = await getRoutesForStop(c.env, stopId);
  return c.json({ stop, routes });
});

app.get("/v1/stops/:stop_id/departures", async c => {
  const stopId = c.req.param("stop_id");
  const limit = Math.min(Number(c.req.query("limit") ?? 15), 50);
  // Cap at a week so callers can peek beyond the typical 2-3h horizon when
  // they need to find the "very next service" after a quiet stretch — even
  // a weekday-only stop checked on a Saturday has its next trip within 7 days.
  const windowMin = Math.min(Number(c.req.query("window_min") ?? 60), 10080);
  return c.json({
    stop_id: stopId,
    departures: await getDepartures(c.env, stopId, windowMin, limit),
  });
});

app.get("/v1/routes/schools", async c => {
  const lat = Number(c.req.query("lat"));
  const lon = Number(c.req.query("lon"));
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    return c.json({ error: "lat and lon required" }, 400);
  }
  const radiusM = Math.min(Math.max(Number(c.req.query("radius_m") ?? 1000), 200), 5000);
  const limit = Math.min(Number(c.req.query("limit") ?? 25), 50);
  return c.json({
    matches: await findSchoolRoutesNear(c.env, lat, lon, radiusM, limit),
  });
});

app.get("/v1/routes/:short_name/stops", async c => {
  const shortName = c.req.param("short_name");
  const result = await getStopsForRoute(c.env, shortName);
  if (!result) return c.json({ error: `no route '${shortName}'` }, 404);
  return c.json(result);
});

app.get("/v1/routes/:short_name/nearest-stop", async c => {
  const shortName = c.req.param("short_name");
  const lat = Number(c.req.query("lat"));
  const lon = Number(c.req.query("lon"));
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    return c.json({ error: "lat and lon required" }, 400);
  }
  const result = await findNearestStopForRoute(c.env, shortName, lat, lon);
  if (!result) return c.json({ error: `no stops found for route ${shortName}` }, 404);
  return c.json(result);
});

app.get("/v1/routes/:route_id", async c => {
  const route = await getRoute(c.env, c.req.param("route_id"));
  if (!route) return c.json({ error: "not found" }, 404);
  return c.json({ route });
});

app.get("/v1/journey", async c => {
  const fromLat = Number(c.req.query("from_lat"));
  const fromLon = Number(c.req.query("from_lon"));
  const toLat = Number(c.req.query("to_lat"));
  const toLon = Number(c.req.query("to_lon"));
  if (![fromLat, fromLon, toLat, toLon].every(Number.isFinite)) {
    return c.json({ error: "from_lat, from_lon, to_lat, to_lon required" }, 400);
  }
  const windowMin = Math.min(Number(c.req.query("window_min") ?? 90), 180);
  // walk_m is the legacy single-value param (pre-1.0.4). walk_to_m /
  // walk_from_m override it per-leg so each side is configurable.
  const walkFallback = Number(c.req.query("walk_m") ?? 500);
  const walkToM   = Math.min(Number(c.req.query("walk_to_m")   ?? walkFallback), 2000);
  const walkFromM = Math.min(Number(c.req.query("walk_from_m") ?? walkFallback), 2000);
  const limit = Math.min(Number(c.req.query("limit") ?? 12), 30);
  // Opt-in flag — 1.0.0 clients won't send this, so they keep getting
  // direct-only results. 1.0.1+ clients pass ?transfers=1 to enable
  // hub-anchored one-transfer journeys.
  const withTransfers = c.req.query("transfers") === "1";
  const options = await planJourney(
    c.env, fromLat, fromLon, toLat, toLon, windowMin, walkToM, walkFromM, limit, withTransfers,
  );
  return c.json({ options });
});

export default app;
