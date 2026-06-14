-- TransLink SEQ GTFS schema for Cloudflare D1
-- Mirrors the GTFS static spec. Columns we don't query are omitted to keep DB lean.
-- Re-running this file is safe: it drops and recreates every table.

DROP TABLE IF EXISTS stop_times;
DROP TABLE IF EXISTS trips;
DROP TABLE IF EXISTS calendar_dates;
DROP TABLE IF EXISTS calendar;
DROP TABLE IF EXISTS routes;
DROP TABLE IF EXISTS stops;
DROP TABLE IF EXISTS agencies;
DROP TABLE IF EXISTS feed_meta;

CREATE TABLE agencies (
  agency_id    TEXT PRIMARY KEY,
  agency_name  TEXT NOT NULL,
  agency_url   TEXT,
  agency_tz    TEXT NOT NULL
);

CREATE TABLE stops (
  stop_id        TEXT PRIMARY KEY,
  stop_code      TEXT,
  stop_name      TEXT NOT NULL,
  stop_lat       REAL NOT NULL,
  stop_lon       REAL NOT NULL,
  location_type  INTEGER DEFAULT 0,
  parent_station TEXT,
  platform_code  TEXT,
  -- Comma-separated GTFS route_type values for the routes serving this stop.
  -- Populated by the ingest finalization step (see scripts/seed.ts).
  -- e.g. "3" (bus only), "3,4" (bus + ferry), "2" (rail only).
  route_types    TEXT
);
CREATE INDEX idx_stops_lat ON stops(stop_lat);
CREATE INDEX idx_stops_lon ON stops(stop_lon);
CREATE INDEX idx_stops_parent ON stops(parent_station);

CREATE TABLE routes (
  route_id         TEXT PRIMARY KEY,
  agency_id        TEXT,
  route_short_name TEXT,
  route_long_name  TEXT,
  route_type       INTEGER NOT NULL,
  route_color      TEXT,
  route_text_color TEXT
);

CREATE TABLE calendar (
  service_id TEXT PRIMARY KEY,
  monday     INTEGER NOT NULL,
  tuesday    INTEGER NOT NULL,
  wednesday  INTEGER NOT NULL,
  thursday   INTEGER NOT NULL,
  friday     INTEGER NOT NULL,
  saturday   INTEGER NOT NULL,
  sunday     INTEGER NOT NULL,
  start_date TEXT NOT NULL,  -- YYYYMMDD
  end_date   TEXT NOT NULL
);

CREATE TABLE calendar_dates (
  service_id     TEXT NOT NULL,
  date           TEXT NOT NULL,    -- YYYYMMDD
  exception_type INTEGER NOT NULL, -- 1=added, 2=removed
  PRIMARY KEY (service_id, date)
);

CREATE TABLE trips (
  trip_id       TEXT PRIMARY KEY,
  route_id      TEXT NOT NULL,
  service_id    TEXT NOT NULL,
  trip_headsign TEXT,
  direction_id  INTEGER,
  shape_id      TEXT,
  block_id      TEXT
);
CREATE INDEX idx_trips_route ON trips(route_id);
CREATE INDEX idx_trips_service ON trips(service_id);

CREATE TABLE stop_times (
  trip_id        TEXT NOT NULL,
  arrival_time   TEXT NOT NULL,   -- HH:MM:SS (may exceed 24h)
  departure_time TEXT NOT NULL,
  stop_id        TEXT NOT NULL,
  stop_sequence  INTEGER NOT NULL,
  pickup_type    INTEGER DEFAULT 0,
  drop_off_type  INTEGER DEFAULT 0,
  PRIMARY KEY (trip_id, stop_sequence)
);
CREATE INDEX idx_stoptimes_stop ON stop_times(stop_id, departure_time);
CREATE INDEX idx_stoptimes_trip ON stop_times(trip_id);

-- Tracks the most recent successful ingest. Useful for the iOS app
-- to display "schedule data current as of...".
CREATE TABLE feed_meta (
  key        TEXT PRIMARY KEY,
  value      TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
