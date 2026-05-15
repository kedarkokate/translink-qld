# TransitQLD

iOS app + Cloudflare Workers backend for the TransLink South East Queensland open data feed (GTFS static + GTFS-Realtime). The on-device app is branded **TransitQLD**; the backend and repository keep the legacy `translink-qld` naming so deployed URLs and stored credentials stay stable.

**v1 scope:** nearby stops, live next departures, vehicle positions on the map.

## Repository layout

```
TransLinkQLD/
├── backend/         Cloudflare Worker (TypeScript) — REST API + GTFS ingest
│   ├── src/         Worker entry, routes, GTFS-RT decode, D1 queries
│   ├── scripts/     GTFS static seeder + status check (laptop-driven)
│   ├── schema.sql   D1 schema (GTFS tables)
│   └── wrangler.toml
└── ios/             SwiftUI app (iOS 17+)
    ├── project.yml          xcodegen config
    └── TransitQLD/          Swift sources
```

## Prerequisites — install in this order

The current machine has **none of these** installed yet.

1. **Xcode** (full app, not just CLT) — App Store, ~15 GB. Required for any iOS build.
2. **Homebrew** — `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"`
3. **Node 22 + xcodegen + wrangler** — once brew is installed:

   ```bash
   brew install node xcodegen
   npm install -g wrangler
   ```

4. **Cloudflare account** — the $5/mo Workers Paid plan is recommended (50M D1 writes/month comfortably covers the GTFS seed). The free tier works for app traffic but its 100K daily write cap makes seeding impractical.

## Backend setup

### 1. Install dependencies

```bash
cd backend
npm install
```

### 2. Create Cloudflare resources

```bash
wrangler login                                          # browser auth
wrangler d1 create translink_qld                        # copy the database_id
wrangler kv namespace create RT_CACHE                   # copy the id
wrangler r2 bucket create translink-qld-gtfs
```

Paste the returned IDs into [backend/wrangler.toml](backend/wrangler.toml) where it says `REPLACE_WITH_*`.

### 3. Apply the schema

```bash
npm run schema:apply:local       # for local dev
npm run schema:apply:remote      # when ready to deploy
```

### 4. Seed GTFS static data

Create `backend/.env` with:

```
D1_ACCOUNT_ID=<your account id, top-right of dashboard>
D1_API_TOKEN=<token with D1:Edit permission>
D1_DATABASE_ID=<same UUID as wrangler.toml>
```

Then:

```bash
npm run seed           # full feed in one pass; ~30–45 min
npm run seed:status    # row counts: remote vs source, per table
```

The seed downloads `SEQ_GTFS.zip` (~50 MB), parses each CSV, and dispatches INSERT batches to D1 with bounded concurrency. It writes a `backend/.seed-state.json` checkpoint every 50k rows — if the run is interrupted (Ctrl-C, lost connection, laptop sleep), rerunning `npm run seed` picks up exactly where it left off. Re-wipe + restart from scratch with `npm run seed -- --restart`.

### 5. Run / deploy

```bash
npm run dev        # http://localhost:8787 (iOS simulator can reach this directly)
npm run deploy     # ships to <name>.<your-subdomain>.workers.dev
```

Once deployed, update [ios/TransLinkQLD/Services/AppConfig.swift](ios/TransLinkQLD/Services/AppConfig.swift) with the production URL.

### Backend endpoints

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/health` | Last ingest timestamp |
| GET | `/v1/stops/nearby?lat=&lon=&radius_m=&limit=` | Bounding-box + Haversine sort |
| GET | `/v1/stops/{stop_id}` | Stop + routes serving it |
| GET | `/v1/stops/{stop_id}/departures?window_min=&limit=` | Schedule merged with realtime delays/cancellations |
| GET | `/v1/routes/{route_id}` | Route detail |
| GET | `/v1/vehicles?bbox=minLon,minLat,maxLon,maxLat` | Live vehicle positions (~20 s cache) |

## iOS setup

```bash
cd ios
xcodegen generate              # creates TransLinkQLD.xcodeproj
open TransLinkQLD.xcodeproj
```

In Xcode: pick a Simulator (e.g. iPhone 15 Pro), ⌘R to run. The first launch will prompt for location permission — accept and you should see nearby stops appear on the map (assuming the Worker is reachable at the URL in `AppConfig`).

> **Physical device:** the simulator can reach `http://localhost:8787`; a physical device cannot. Either deploy the Worker (`npm run deploy`) and point `AppConfig` at the workers.dev URL, or use your Mac's LAN IP (and add the relevant `NSAppTransportSecurity` exception in Info.plist).

## Known limitations / next steps

- **Bulk ingest is laptop-driven by design.** Run `npm run seed` whenever TransLink republishes the feed (typically weekly). The script parallelises writes against D1's REST API and finishes in ~30–45 min. Use `npm run seed:status` to verify counts. Moving the ingest server-side would mean a Workers + Queues + R2 pipeline (one queue message per GTFS file) — out of scope while the laptop flow works.
- **No trip planner.** v1 is "what's near me, what's leaving next." A→B routing needs either an external service (OpenTripPlanner) or a graph-search engine on top of GTFS.
- **No alerts feed parsing yet.** The TransLink GTFS-RT Alerts URL is wired into `wrangler.toml` but not surfaced through an endpoint.
- **No offline mode.** Every screen depends on the Worker being reachable. A future v1.1 could cache the last `nearby` and `departures` responses in `URLCache` + `Disk`.
- **Time zone handling for `departure_time`** assumes Brisbane (UTC+10, no DST). This is correct for SEQ but rebuild the helpers in [backend/src/queries.ts](backend/src/queries.ts) if you extend to other regions.

## Data attribution

> Static and Realtime data published by Queensland Department of Transport and Main Roads / TransLink under Creative Commons Attribution 4.0. https://translink.com.au/about-translink/open-data
