#!/usr/bin/env bash
#
# Wrapper invoked by ~/Library/LaunchAgents/au.com.transitqld.daily-seed.plist
# once a day. Checks the upstream GTFS ETag and only triggers a full seed
# when TransLink has republished the feed (most days: instant no-op).
#
# launchd doesn't inherit the user's shell PATH, so we set up Homebrew env
# explicitly before invoking npm.
set -e
set -o pipefail

eval "$(/opt/homebrew/bin/brew shellenv)"
cd "$HOME/Projects/TransLinkQLD/backend"

ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }
echo
echo "──── [$(ts)] feed check begin ────"
if ! npm run seed:if-changed; then
  echo "──── [$(ts)] feed check FAILED (exit $?) ────"
  exit 1
fi
echo "──── [$(ts)] feed check end ────"
