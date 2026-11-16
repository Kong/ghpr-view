#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-build}"
derived="${GHPR_PROFILE_BUILD_DIR:-/tmp/ghpr-profile-build}"
output="${GHPR_PROFILE_OUTPUT:-/tmp/ghpr-profile-$(date +%Y%m%dT%H%M%S).json}"
binary="$derived/Build/Products/Release/PRDashboard.app/Contents/MacOS/PRDashboard"

case "$mode" in
  build)
    xcodebuild -project PRDashboard.xcodeproj -scheme PRDashboard \
      -configuration Release -derivedDataPath "$derived" \
      SWIFT_COMPILATION_MODE=singlefile \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) GHPR_PROFILE' \
      CODE_SIGNING_ALLOWED=NO build
    ;;
  run)
    test -x "$binary"
    GHPR_PROFILE_OUTPUT="$output" "$binary" --performance-scenario --uiux-count="${GHPR_PROFILE_COUNT:-100}"
    echo "Profile report: $output"
    ;;
  trace)
    test -x "$binary"
    template="${2:-SwiftUI}"
    trace="${GHPR_PROFILE_TRACE:-${output%.json}.trace}"
    GHPR_PROFILE_OUTPUT="$output" "$binary" --performance-scenario \
      --uiux-count="${GHPR_PROFILE_COUNT:-100}" &
    scenario_pid=$!
    trap 'kill "$scenario_pid" 2>/dev/null || true' EXIT
    xcrun xctrace record --template "$template" --output "$trace" \
      --attach "$scenario_pid" --time-limit 30s --no-prompt
    wait "$scenario_pid"
    trap - EXIT
    echo "Instruments recording: $trace"
    ;;
  *)
    echo 'Usage: bash profile.sh build | run | trace ["SwiftUI" | "Time Profiler" | "Metal System Trace"]' >&2
    exit 2
    ;;
esac
