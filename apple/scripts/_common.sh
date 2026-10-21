#!/bin/sh
set -eu
APPLE_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO_ROOT=$(CDPATH= cd -- "$APPLE_DIR/.." && pwd)
BUILD_ROOT="$REPO_ROOT/build/apple"
require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$1" >&2
        return 127
    fi
}
ensure_build_root() { mkdir -p "$BUILD_ROOT/logs" "$BUILD_ROOT/DerivedData"; }
resolve_configuration() {
    case "${CONFIGURATION:-Debug}" in
        Debug|Release) printf '%s\n' "${CONFIGURATION:-Debug}" ;;
        *) printf 'Invalid CONFIGURATION: %s. Use Debug or Release.\n' "$CONFIGURATION" >&2; return 2 ;;
    esac
}
resolve_ios_simulator_destination() {
    require_command xcrun
    require_command python3
    require_command xcodebuild
    python3 "$APPLE_DIR/scripts/_simulator_destinations.py" \
        --project "$APPLE_DIR/VaganciaFitness.xcodeproj" --scheme "${1:-VaganciaFitness}" \
        --configuration "$(resolve_configuration)" --destination "${DESTINATION:-}"
}
run_logged() {
    label=$1; shift
    ensure_build_root
    logfile="$BUILD_ROOT/logs/$label-$(date +%Y%m%d-%H%M%S).log"
    printf 'Log: %s\n' "$logfile"
    if "$@" >"$logfile" 2>&1; then tail -n 35 "$logfile"; else
        result=$?; tail -n 100 "$logfile" >&2
        printf 'Command failed (%s); full log: %s\n' "$result" "$logfile" >&2
        return "$result"
    fi
}
