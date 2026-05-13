#!/usr/bin/env bash
#
# run-local.sh — build and run the TransLinkQLD iOS app against the local
# Cloudflare Worker.
#
# Sequence:
#   1. Ensure Homebrew env is loaded (so node/wrangler are on PATH).
#   2. Start `wrangler dev` on :8787 if it isn't already up.
#   3. Boot an iOS Simulator (existing one or first available iPhone model).
#   4. Build the Debug configuration of the iOS app.
#   5. Install and launch the app on the booted Simulator.
#
# Usage:
#   ./run-local.sh                              # default flow
#   ./run-local.sh --location -27.466,153.026   # also seed Sim location
#
# The script is idempotent — re-running it just rebuilds the app and
# reinstalls it; the existing wrangler dev process is reused.
#

set -euo pipefail

# Resolve to the directory the script lives in, so it works from anywhere.
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$PROJECT_DIR/backend"
IOS_DIR="$PROJECT_DIR/ios"
BUNDLE_ID="au.com.translinkqld.app"
SCHEME="TransLinkQLD"
PORT=8787
SIM_FALLBACKS=("iPhone 17 Pro" "iPhone 17" "iPhone 16 Pro" "iPhone 16" "iPhone 15 Pro" "iPhone 15")

# --- arg parsing ---------------------------------------------------------
SET_LOCATION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)
      SET_LOCATION="${2:-}"; shift 2
      [[ -z "$SET_LOCATION" ]] && { echo "--location needs lat,lon"; exit 1; }
      ;;
    -h|--help)
      sed -n '2,/^$/{ /^#!/d; s/^# \{0,1\}//p; }' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $1"; exit 1
      ;;
  esac
done

# --- 0) Homebrew env -----------------------------------------------------
if [[ -x /opt/homebrew/bin/brew ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi

# --- 1) wrangler dev -----------------------------------------------------
if curl -fsS "http://localhost:$PORT/v1/health" >/dev/null 2>&1; then
  echo "✓ wrangler dev already running on :$PORT"
else
  echo "▸ starting wrangler dev on :$PORT  (logs: $BACKEND_DIR/wrangler.log)"
  (
    cd "$BACKEND_DIR"
    nohup npx wrangler dev --port $PORT > wrangler.log 2>&1 &
    disown
  )
  echo -n "  waiting for ready"
  for i in {1..30}; do
    sleep 1
    echo -n "."
    if curl -fsS "http://localhost:$PORT/v1/health" >/dev/null 2>&1; then
      echo " ready"
      break
    fi
    if [[ $i -eq 30 ]]; then
      echo
      echo "✗ wrangler didn't come up; see $BACKEND_DIR/wrangler.log"
      exit 1
    fi
  done
fi

# --- 2) boot a Simulator -------------------------------------------------
if ! xcrun simctl list devices booted 2>&1 | grep -q "Booted"; then
  BOOTED=""
  for SIM in "${SIM_FALLBACKS[@]}"; do
    if xcrun simctl boot "$SIM" 2>/dev/null; then
      BOOTED="$SIM"
      break
    fi
  done
  if [[ -z "$BOOTED" ]]; then
    echo "✗ no iPhone simulator from fallbacks: ${SIM_FALLBACKS[*]}"
    exit 1
  fi
  echo "✓ booted $BOOTED"
else
  echo "✓ Simulator already booted"
fi
open -a Simulator

# --- 3) (optional) set Sim location --------------------------------------
if [[ -n "$SET_LOCATION" ]]; then
  xcrun simctl location booted set "$SET_LOCATION"
  echo "✓ Sim location set to $SET_LOCATION"
fi

# --- 4) build the Debug app ---------------------------------------------
echo "▸ building $SCHEME (Debug)"
cd "$IOS_DIR"
xcodebuild \
  -project "$SCHEME.xcodeproj" \
  -scheme "$SCHEME" \
  -destination 'generic/platform=iOS Simulator' \
  -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO 2>&1 \
  | tail -3

# --- 5) install + launch -------------------------------------------------
APP=$(find ~/Library/Developer/Xcode/DerivedData \
        -path "*Debug-iphonesimulator/$SCHEME.app" -type d 2>/dev/null \
      | head -1)
if [[ -z "$APP" ]]; then
  echo "✗ couldn't locate the built .app bundle"
  exit 1
fi

echo "▸ installing $APP"
xcrun simctl terminate booted "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install booted "$APP"
xcrun simctl launch booted "$BUNDLE_ID"

cat <<EOF

✓ Done. App is running against http://localhost:$PORT.

   tail -f $BACKEND_DIR/wrangler.log     # backend logs
   xcrun simctl location booted set <lat>,<lon>     # change Sim location
EOF
