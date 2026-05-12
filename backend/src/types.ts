export interface Env {
  DB: D1Database;
  RT_CACHE: KVNamespace;
  TRANSLINK_GTFS_URL: string;
  TRANSLINK_RT_TRIP_UPDATES: string;
  TRANSLINK_RT_VEHICLE_POSITIONS: string;
  TRANSLINK_RT_ALERTS: string;
  RT_CACHE_TTL_SECONDS: string;
}

export interface Stop {
  stop_id: string;
  stop_code: string | null;
  stop_name: string;
  stop_lat: number;
  stop_lon: number;
  location_type: number;
  parent_station: string | null;
  platform_code: string | null;
}

export interface StopWithDistance extends Stop {
  distance_m: number;
}

export interface Route {
  route_id: string;
  route_short_name: string | null;
  route_long_name: string | null;
  route_type: number;
  route_color: string | null;
  route_text_color: string | null;
}

export interface Departure {
  trip_id: string;
  route_id: string;
  route_short_name: string | null;
  route_long_name: string | null;
  route_type: number;
  headsign: string | null;
  scheduled_departure: string;  // ISO-8601 in stop's TZ
  predicted_departure: string | null;
  delay_seconds: number | null;
  is_realtime: boolean;
  is_cancelled: boolean;
}

export interface VehiclePosition {
  vehicle_id: string;
  trip_id: string | null;
  route_id: string | null;
  lat: number;
  lon: number;
  bearing: number | null;
  speed: number | null;
  timestamp: number;
}
