#!/bin/bash
# Wrapper invoked by ~/Library/LaunchAgents/com.kedarkokate.translink-qld-seed.plist.
# launchd doesn't inherit the user's shell PATH, so we set it up here before
# running the chunked seed.
set -e
set -o pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
cd "$HOME/Projects/TransLinkQLD/backend"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
echo
echo "──── [$(ts)] daily seed begin ────"
if ! npm run seed:remote; then
  echo "──── [$(ts)] daily seed FAILED (exit $?) ────"
  exit 1
fi
echo "──── [$(ts)] daily seed end ────"
