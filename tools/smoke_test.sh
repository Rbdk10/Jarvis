#!/usr/bin/env bash
# Pre-ship smoke test: build the app for a simulator, launch it, and fail if it
# doesn't build or crashes within a watch window. Run from the repo root.
#
# Catches: build breaks, launch/init crashes, missing Info.plist permission keys,
# nil-unwrap-on-launch, etc. (Note: device-specific audio behaviour can differ from
# the simulator, so this is a strong floor, not a guarantee for every audio path.)
set -uo pipefail

BUNDLE_ID="com.agrisol.Jarvis"
SCHEME="Jarvis"
WATCH="${SMOKE_WATCH:-18}"
DERIVED="$(mktemp -d)"
CRASHDIR="$HOME/Library/Logs/DiagnosticReports"

cleanup() { [ -n "${UDID:-}" ] && xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "▸ [smoke] building $SCHEME for the simulator…"
if ! xcodebuild -project Jarvis.xcodeproj -scheme "$SCHEME" \
      -destination 'generic/platform=iOS Simulator' -configuration Debug \
      -derivedDataPath "$DERIVED" build CODE_SIGNING_ALLOWED=NO \
      >/tmp/jarvis-smoke-build.log 2>&1; then
  echo "✗ [smoke] BUILD FAILED"; grep -E "error:" /tmp/jarvis-smoke-build.log | head; exit 1
fi
APP="$(find "$DERIVED/Build/Products" -name "$SCHEME.app" -type d | head -1)"
[ -z "$APP" ] && { echo "✗ [smoke] no .app produced"; exit 1; }

# Pick an available iPhone simulator and boot it.
UDID="$(xcrun simctl list devices available | grep -oE '\([0-9A-Fa-f-]{36}\)' | tr -d '()' | head -1)"
[ -z "$UDID" ] && { echo "✗ [smoke] no available simulator"; exit 1; }
xcrun simctl boot "$UDID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true

xcrun simctl install "$UDID" "$APP"
# Pre-grant permissions so the app runs its real idle/listening path (not a prompt).
xcrun simctl privacy "$UDID" grant microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl privacy "$UDID" grant speech-recognition "$BUNDLE_ID" >/dev/null 2>&1 || true

BEFORE="$(ls "$CRASHDIR"/${SCHEME}-* 2>/dev/null | wc -l | tr -d ' ')"
echo "▸ [smoke] launching and watching ${WATCH}s for a crash…"
xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || { echo "✗ [smoke] launch failed"; exit 1; }
sleep "$WATCH"

AFTER="$(ls "$CRASHDIR"/${SCHEME}-* 2>/dev/null | wc -l | tr -d ' ')"
ALIVE="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -c "$BUNDLE_ID" || true)"

if [ "$AFTER" -gt "$BEFORE" ]; then
  echo "✗ [smoke] FAILED — app crashed (new crash report):"
  ls -t "$CRASHDIR"/${SCHEME}-* | head -1
  exit 1
fi
if [ "$ALIVE" -eq 0 ]; then
  echo "✗ [smoke] FAILED — app not running after ${WATCH}s (crashed or exited early)"; exit 1
fi
echo "✓ [smoke] PASSED — app launched and stayed up ${WATCH}s"
