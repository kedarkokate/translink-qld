# TransitQLD

iOS app + Cloudflare Workers backend for the TransLink South East Queensland open data feed (GTFS static + GTFS-Realtime). The on-device app is branded **TransitQLD**; the backend and repository keep the legacy `translink-qld` naming so deployed URLs and stored credentials stay stable.

**v1 scope:** nearby stops, live next departures, vehicle positions on the map.

## Repository layout

```
TransLinkQLD/
├── backend/         Cloudflare Worker (TypeScript) — REST API + GTFS ingest
│   ├── src/         Worker entry, routes, GTFS-RT decode, D1 queries
│   ├── scripts/     One-shot GTFS static ingest (run from your laptop)
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

4. **Cloudflare account** — free tier is fine for everything except cron triggers (requires the $5/mo Workers Paid plan, but you can skip that and run the daily ingest from your laptop or CI).

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

For local dev:

```bash
npm run seed:local
```

For your live D1, create `backend/.env` with:

```
CF_ACCOUNT_ID=<your account id, top-right of dashboard>
CF_API_TOKEN=<token with D1:Edit permission>
CF_D1_DATABASE_ID=<same UUID as wrangler.toml>
```

Then:

```bash
npm run seed:remote
```

The seed downloads `SEQ_GTFS.zip` (~50 MB), parses each CSV, and bulk-inserts in 500-row batches. Expect 10–30 minutes for the full feed (stop_times.txt is several million rows). Re-running is safe — each table is truncated first.

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

- **Bulk ingest currently runs from your laptop.** The Worker's `scheduled` handler just records that the cron fired — it doesn't yet do the actual ingest. To automate: either (a) run `seed:remote` from a GitHub Actions cron, or (b) move the ingest into a Workers + Queues pipeline (R2 stages the zip, a queue consumer processes one GTFS file per message — needed because a single Worker invocation can't process millions of stop_times rows within CPU limits).
- **No trip planner.** v1 is "what's near me, what's leaving next." A→B routing needs either an external service (OpenTripPlanner) or a graph-search engine on top of GTFS.
- **No alerts feed parsing yet.** The TransLink GTFS-RT Alerts URL is wired into `wrangler.toml` but not surfaced through an endpoint.
- **No offline mode.** Every screen depends on the Worker being reachable. A future v1.1 could cache the last `nearby` and `departures` responses in `URLCache` + `Disk`.
- **Time zone handling for `departure_time`** assumes Brisbane (UTC+10, no DST). This is correct for SEQ but rebuild the helpers in [backend/src/queries.ts](backend/src/queries.ts) if you extend to other regions.

## Data attribution

> Static and Realtime data published by Queensland Department of Transport and Main Roads / TransLink under Creative Commons Attribution 4.0. https://translink.com.au/about-translink/open-data
