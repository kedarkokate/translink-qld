import { Hono } from "hono";
import { cors } from "hono/cors";
import type { Env } from "./types";
import {
  findNearbyStops, getStop, getRoutesForStop,
  getRoute, getDepartures, findNearestStopForRoute, searchStops,
  planJourney, getStopsForRoute,
} from "./queries";
import { getVehiclePositions } from "./gtfsRt";

const app = new Hono<{ Bindings: Env }>();

app.use("*", cors({ origin: "*", maxAge: 600 }));

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
  const radiusM = Math.min(Number(c.req.query("radius_m") ?? 500), 5000);
  const limit = Math.min(Number(c.req.query("limit") ?? 25), 100);
  if (!Number.isFinite(lat) || !Number.isFinite(lon)) {
    return c.json({ error: "lat and lon required" }, 400);
  }
  return c.json({ stops: await findNearbyStops(c.env, lat, lon, radiusM, limit) });
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
  const windowMin = Math.min(Number(c.req.query("window_min") ?? 60), 180);
  return c.json({
    stop_id: stopId,
    departures: await getDepartures(c.env, stopId, windowMin, limit),
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
  const walkRadiusM = Math.min(Number(c.req.query("walk_m") ?? 500), 800);
  const limit = Math.min(Number(c.req.query("limit") ?? 12), 30);
  const options = await planJourney(
    c.env, fromLat, fromLon, toLat, toLon, windowMin, walkRadiusM, limit,
  );
  return c.json({ options });
});

app.get("/v1/vehicles", async c => {
  const bbox = c.req.query("bbox");  // "minLon,minLat,maxLon,maxLat"
  const all = await getVehiclePositions(c.env);
  if (!bbox) return c.json({ vehicles: all });
  const [minLon, minLat, maxLon, maxLat] = bbox.split(",").map(Number);
  const filtered = all.filter(v =>
    v.lat >= minLat && v.lat <= maxLat &&
    v.lon >= minLon && v.lon <= maxLon
  );
  return c.json({ vehicles: filtered });
});

export default {
  fetch: app.fetch,

  async scheduled(_event: ScheduledEvent, env: Env, ctx: ExecutionContext) {
    // Daily GTFS refresh. The actual ingest is heavy (large file, many rows)
    // so production deployments should run `npm run seed:remote` from CI
    // instead. This handler currently records that the cron fired — wire in
    // a proper ingest pipeline (R2 staging + chunked D1 inserts) when ready.
    ctx.waitUntil(env.DB.prepare(
      `INSERT INTO feed_meta(key, value, updated_at)
       VALUES('last_cron_fire', ?1, ?2)
       ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at`
    ).bind(new Date().toISOString(), Math.floor(Date.now() / 1000)).run());
  },
};
