import GtfsRealtimeBindings from "gtfs-realtime-bindings";
import type { Env } from "./types";

const { FeedMessage } = GtfsRealtimeBindings.transit_realtime;

type CachedFeed<T> = { fetchedAt: number; data: T };

async function fetchAndDecode(url: string) {
  const res = await fetch(url, { cf: { cacheTtl: 10 } });
  if (!res.ok) throw new Error(`RT feed ${url} returned ${res.status}`);
  const buf = new Uint8Array(await res.arrayBuffer());
  return FeedMessage.decode(buf);
}

async function cached<T>(
  env: Env,
  key: string,
  loader: () => Promise<T>,
): Promise<T> {
  const ttl = Number(env.RT_CACHE_TTL_SECONDS) || 20;
  const hit = await env.RT_CACHE.get(key, "json") as CachedFeed<T> | null;
  if (hit && Date.now() - hit.fetchedAt < ttl * 1000) return hit.data;
  const data = await loader();
  await env.RT_CACHE.put(
    key,
    JSON.stringify({ fetchedAt: Date.now(), data }),
    { expirationTtl: Math.max(ttl, 60) },
  );
  return data;
}

export interface TripUpdate {
  trip_id: string;
  route_id: string | null;
  schedule_relationship: number | null;  // 0=scheduled, 3=cancelled
  stop_time_updates: {
    stop_id: string | null;
    stop_sequence: number | null;
    arrival_delay: number | null;
    departure_delay: number | null;
  }[];
}

export async function getTripUpdates(env: Env): Promise<Map<string, TripUpdate>> {
  const feed = await cached(env, "trip_updates_raw", async () => {
    const decoded = await fetchAndDecode(env.TRANSLINK_RT_TRIP_UPDATES);
    const out: TripUpdate[] = [];
    for (const e of decoded.entity ?? []) {
      const tu = e.tripUpdate;
      if (!tu?.trip?.tripId) continue;
      out.push({
        trip_id: tu.trip.tripId,
        route_id: tu.trip.routeId ?? null,
        schedule_relationship: tu.trip.scheduleRelationship ?? null,
        stop_time_updates: (tu.stopTimeUpdate ?? []).map(s => ({
          stop_id: s.stopId ?? null,
          stop_sequence: s.stopSequence ?? null,
          arrival_delay: s.arrival?.delay ?? null,
          departure_delay: s.departure?.delay ?? null,
        })),
      });
    }
    return out;
  });
  return new Map(feed.map(t => [t.trip_id, t]));
}
