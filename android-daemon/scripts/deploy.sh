#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SERIAL=""
PORT=27189
DEBOUNCE_MS=20
MAX_DEPTH=48
HEARTBEAT_MS=5000
DEX_JAR="$PROJECT_DIR/build/dist/android-daemon.jar"
REMOTE_JAR="/data/local/tmp/android-daemon.jar"
STOP_ONLY=0
DETACHED=0
MEANINGFUL_ONLY=0
INCLUDE_UNIMPORTANT=0
INCLUDE_INVISIBLE=0
VERBOSE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]
  --serial <id>             ADB device serial (auto-selects if exactly 1 device attached)
  --port <port>             Loopback TCP port (default: $PORT)
  --debounce-ms <ms>        Accessibility burst coalescing window (default: $DEBOUNCE_MS)
  --max-depth <n>           Max UI hierarchy depth (default: $MAX_DEPTH)
  --heartbeat-ms <ms>       Heartbeat interval in ms (default: $HEARTBEAT_MS)
  --dex-jar <path>          Path to android-daemon.jar (default: $DEX_JAR)
  --meaningful-only         Filter to meaningful AndroidUINode elements
  --include-unimportant     Include non-important accessibility views
  --include-invisible       Include invisible nodes
  --verbose                 Enable verbose daemon stderr logging
  --detached                Start daemon in background on device and return after ready
  --stop                    Stop running daemon on device and remove adb forward
  -h, --help                Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --serial) SERIAL="${2:?Missing value for --serial}"; shift 2 ;;
    --port) PORT="${2:?Missing value for --port}"; shift 2 ;;
    --debounce-ms) DEBOUNCE_MS="${2:?Missing value for --debounce-ms}"; shift 2 ;;
    --max-depth) MAX_DEPTH="${2:?Missing value for --max-depth}"; shift 2 ;;
    --heartbeat-ms) HEARTBEAT_MS="${2:?Missing value for --heartbeat-ms}"; shift 2 ;;
    --dex-jar) DEX_JAR="${2:?Missing value for --dex-jar}"; shift 2 ;;
    --meaningful-only) MEANINGFUL_ONLY=1; shift ;;
    --include-unimportant) INCLUDE_UNIMPORTANT=1; shift ;;
    --include-invisible) INCLUDE_INVISIBLE=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    --detached) DETACHED=1; shift ;;
    --stop) STOP_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if ! command -v adb >/dev/null 2>&1; then
  echo "ERROR: adb not found in PATH." >&2
  exit 1
fi

if [[ -z "$SERIAL" ]]; then
  DEVICES=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && DEVICES+=("$line")
  done < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')

  if [[ "${#DEVICES[@]}" -eq 0 ]]; then
    echo "ERROR: No online ADB devices found." >&2
    exit 1
  elif [[ "${#DEVICES[@]}" -gt 1 ]]; then
    echo "ERROR: Multiple ADB devices found (${DEVICES[*]}). Specify --serial <id>." >&2
    exit 1
  fi
  SERIAL="${DEVICES[0]}"
fi

ADB=(adb -s "$SERIAL")

stop_remote_daemon() {
  "${ADB[@]}" shell "
    if pkill -f '[c]om.shadowgraph.daemon.DaemonMain' >/dev/null 2>&1; then
      i=0
      while [ \$i -lt 20 ]; do
        pgrep -f '[c]om.shadowgraph.daemon.DaemonMain' >/dev/null 2>&1 || break
        sleep 0.05
        i=\$((i + 1))
      done
      pkill -9 -f '[c]om.shadowgraph.daemon.DaemonMain' >/dev/null 2>&1 || true
    fi
  " >/dev/null 2>&1 || true
  "${ADB[@]}" forward --remove "tcp:${PORT}" >/dev/null 2>&1 || true
}

if [[ "$STOP_ONLY" -eq 1 ]]; then
  stop_remote_daemon
  echo "Stopped android-daemon on $SERIAL and removed tcp:$PORT forward."
  exit 0
fi

if [[ ! -f "$DEX_JAR" ]]; then
  echo "ERROR: DEX artifact not found at $DEX_JAR. Run ./scripts/build-dex.sh first." >&2
  exit 1
fi

# Idempotent SHA-256 cached upload
LOCAL_SHA="$(shasum -a 256 "$DEX_JAR" | awk '{print $1}')"
REMOTE_SHA="$("${ADB[@]}" shell "sha256sum '$REMOTE_JAR' 2>/dev/null || toybox sha256sum '$REMOTE_JAR' 2>/dev/null" | awk '{print $1}' | tr -d '\r' || true)"

if [[ "$LOCAL_SHA" != "$REMOTE_SHA" || -z "$REMOTE_SHA" ]]; then
  echo "Pushing $DEX_JAR -> $REMOTE_JAR ($SERIAL)..." >&2
  "${ADB[@]}" push "$DEX_JAR" "$REMOTE_JAR" >/dev/null
  "${ADB[@]}" shell "chmod 644 '$REMOTE_JAR'"
else
  echo "Remote JAR checksum matches ($LOCAL_SHA); skipping adb push." >&2
fi

stop_remote_daemon
"${ADB[@]}" forward "tcp:${PORT}" "tcp:${PORT}" >/dev/null

DAEMON_ARGS=(
  "--port=$PORT"
  "--debounce-ms=$DEBOUNCE_MS"
  "--max-depth=$MAX_DEPTH"
  "--heartbeat-ms=$HEARTBEAT_MS"
)
[[ "$MEANINGFUL_ONLY" -eq 1 ]] && DAEMON_ARGS+=("--meaningful-only")
[[ "$INCLUDE_UNIMPORTANT" -eq 1 ]] && DAEMON_ARGS+=("--include-unimportant")
[[ "$INCLUDE_INVISIBLE" -eq 1 ]] && DAEMON_ARGS+=("--include-invisible")
[[ "$DETACHED" -eq 1 ]] && DAEMON_ARGS+=("--no-stdin-watchdog")
[[ "$VERBOSE" -eq 1 ]] && DAEMON_ARGS+=("--verbose")

REMOTE_CMD="env CLASSPATH=$REMOTE_JAR app_process / com.shadowgraph.daemon.DaemonMain ${DAEMON_ARGS[*]}"

if [[ "$DETACHED" -eq 1 ]]; then
  REMOTE_LOG="/data/local/tmp/android-daemon.log"
  "${ADB[@]}" shell "rm -f '$REMOTE_LOG'; (setsid $REMOTE_CMD </dev/null >'$REMOTE_LOG' 2>&1 &) </dev/null >/dev/null 2>&1" </dev/null
  for _ in $(seq 1 50); do
    if "${ADB[@]}" shell "grep -q 'SHADOWGRAPH_DAEMON_READY' '$REMOTE_LOG' 2>/dev/null"; then
      "${ADB[@]}" shell "cat '$REMOTE_LOG'"
      exit 0
    fi
    sleep 0.1
  done
  echo "ERROR: Daemon failed to signal readiness in detached mode. Remote log:" >&2
  "${ADB[@]}" shell "cat '$REMOTE_LOG' 2>/dev/null || true" >&2
  exit 1
fi

cleanup() {
  stop_remote_daemon
}
trap cleanup EXIT INT TERM

echo "Starting android-daemon on $SERIAL (127.0.0.1:$PORT)..." >&2
"${ADB[@]}" shell "$REMOTE_CMD"
