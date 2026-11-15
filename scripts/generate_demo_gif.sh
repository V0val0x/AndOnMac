#!/usr/bin/env bash
# ==============================================================================
# AndOnMac Layer 3 Showcase Demo GIF Generator
# Captures the running AndOnMac window while executing an autonomous A* macro
# (e.g., "Navigate to Battery Share") and encodes an optimized < 5MB GIF.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Defaults
WINDOW_ID="${WINDOW_ID:-}"
DEVICE_SERIAL="${DEVICE_SERIAL:-61061JEA307110}"
TARGET_HINT="${TARGET_HINT:-Battery Share}"
MCP_PORT="${MCP_PORT:-8765}"
MCP_TOKEN="${ANDONMAC_MCP_TOKEN:-}"
DURATION_SEC=8
FPS=15
MAX_WIDTH=800
MAX_GIF_BYTES=5000000
OUTPUT_GIF="${REPO_ROOT}/assets/demo-layer3-agentic-hud.gif"
MANUAL_TRIGGER=false
KEEP_MP4=false

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [WINDOW_ID]

Automates recording an ${DURATION_SEC}s AndOnMac Layer 3 demo video via macOS screencapture
and converts it via ffmpeg (palettegen/paletteuse, max ${MAX_WIDTH}px, ${FPS}fps) to a <5MB GIF.

Options:
  -w, --window-id ID      macOS CGWindowID of the AndOnMac window (skips prompt)
  -s, --serial SERIAL     Android ADB serial (default: ${DEVICE_SERIAL})
  -t, --target HINT       Layer 3 navigation target hint (default: "${TARGET_HINT}")
  -p, --port PORT         AndOnMac MCP HTTP server port (default: ${MCP_PORT})
      --token TOKEN       Optional MCP HTTP Bearer token (or set ANDONMAC_MCP_TOKEN)
  -d, --duration SEC      Recording duration in seconds (default: ${DURATION_SEC})
  -o, --output PATH       Output GIF path (default: ${OUTPUT_GIF})
      --manual            Prompt for manual hotkey trigger instead of curl MCP call
      --keep-mp4          Keep the intermediate .mp4 next to the output GIF
  -h, --help              Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--window-id)
            WINDOW_ID="${2:?Missing value for --window-id}"
            shift 2
            ;;
        -s|--serial)
            DEVICE_SERIAL="${2:?Missing value for --serial}"
            shift 2
            ;;
        -t|--target)
            TARGET_HINT="${2:?Missing value for --target}"
            shift 2
            ;;
        -p|--port)
            MCP_PORT="${2:?Missing value for --port}"
            shift 2
            ;;
        --token)
            MCP_TOKEN="${2:?Missing value for --token}"
            shift 2
            ;;
        -d|--duration)
            DURATION_SEC="${2:?Missing value for --duration}"
            shift 2
            ;;
        -o|--output)
            OUTPUT_GIF="${2:?Missing value for --output}"
            shift 2
            ;;
        --manual)
            MANUAL_TRIGGER=true
            shift
            ;;
        --keep-mp4)
            KEEP_MP4=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Error: Unknown option '$1'" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -z "${WINDOW_ID}" ]]; then
                WINDOW_ID="$1"
                shift
            else
                echo "Error: Unexpected positional argument '$1'" >&2
                usage >&2
                exit 1
            fi
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Preflight Dependency Checks
# ------------------------------------------------------------------------------
for cmd in screencapture ffmpeg curl; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
        echo "Error: Required tool '${cmd}' not found in PATH." >&2
        if [[ "${cmd}" == "ffmpeg" ]]; then
            echo "Install with: brew install ffmpeg" >&2
        fi
        exit 1
    fi
done

if ! [[ "${DURATION_SEC}" =~ ^[0-9]+$ ]] || [[ "${DURATION_SEC}" -lt 1 ]]; then
    echo "Error: --duration must be a positive integer (got '${DURATION_SEC}')." >&2
    exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/andonmac_demo.XXXXXX")"
RAW_MP4="${TMP_DIR}/capture.mp4"
PALETTE_PNG="${TMP_DIR}/palette.png"
CAPTURE_PID=""

cleanup() {
    if [[ -n "${CAPTURE_PID}" ]] && kill -0 "${CAPTURE_PID}" >/dev/null 2>&1; then
        kill -INT "${CAPTURE_PID}" >/dev/null 2>&1 || true
        wait "${CAPTURE_PID}" >/dev/null 2>&1 || true
    fi
    rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Resolve AndOnMac Window ID (CLI arg, CoreGraphics auto-detect, or user prompt)
# ------------------------------------------------------------------------------
discover_andonmac_windows() {
    if ! command -v swift >/dev/null 2>&1; then
        return 0
    fi
    swift -e '
import CoreGraphics
import Foundation
let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
if let infoList = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
    for w in infoList {
        let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
        let layer = (w[kCGWindowLayer as String] as? Int) ?? -1
        guard owner == "AndOnMac", layer == 0 else { continue }
        if let num = w[kCGWindowNumber as String] as? Int,
           let bounds = w[kCGWindowBounds as String] as? [String: Any] {
            let bw = Int((bounds["Width"] as? Double) ?? 0)
            let bh = Int((bounds["Height"] as? Double) ?? 0)
            let rawName = (w[kCGWindowName as String] as? String) ?? ""
            let name = rawName.isEmpty ? "Mirror Window" : rawName
            if bw >= 120 && bh >= 200 {
                print("\(num)\t\(bw)x\(bh)\t\(name)")
            }
        }
    }
}
' 2>/dev/null || true
}

PICK_INTERACTIVE=false
if [[ -z "${WINDOW_ID}" ]]; then
    echo "==> Detecting on-screen AndOnMac windows..."
    DETECTED_LIST="$(discover_andonmac_windows)"

    if [[ -n "${DETECTED_LIST}" ]]; then
        echo "Detected AndOnMac window(s):"
        echo "${DETECTED_LIST}" | awk -F'\t' '{ printf "  Window ID: %-8s Size: %-10s Title: %s\n", $1, $2, $3 }'
        DEFAULT_WID="$(echo "${DETECTED_LIST}" | head -n 1 | cut -f1)"
        read -r -p "Press [Enter] to use Window ID ${DEFAULT_WID}, enter another ID, or type 'pick' to click window: " USER_INPUT
        if [[ "${USER_INPUT}" == "pick" ]]; then
            PICK_INTERACTIVE=true
        elif [[ -n "${USER_INPUT}" ]]; then
            WINDOW_ID="${USER_INPUT}"
        else
            WINDOW_ID="${DEFAULT_WID}"
        fi
    else
        echo "Could not auto-detect an AndOnMac window ID."
        read -r -p "Enter AndOnMac Window ID (or press [Enter] / type 'pick' to click the window interactively): " USER_INPUT
        if [[ -z "${USER_INPUT}" || "${USER_INPUT}" == "pick" ]]; then
            PICK_INTERACTIVE=true
        else
            WINDOW_ID="${USER_INPUT}"
        fi
    fi
fi

if [[ "${PICK_INTERACTIVE}" == false ]] && ! [[ "${WINDOW_ID}" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid Window ID '${WINDOW_ID}'. Expected numeric CGWindowID." >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# JSON Escape Helper (pure bash)
# ------------------------------------------------------------------------------
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

trigger_layer3_macro() {
    local mcp_url="http://127.0.0.1:${MCP_PORT}/message"
    local health_url="http://127.0.0.1:${MCP_PORT}/"
    local -a auth_args=()
    if [[ -n "${MCP_TOKEN}" ]]; then
        auth_args=(-H "Authorization: Bearer ${MCP_TOKEN}")
    fi

    if [[ "${MANUAL_TRIGGER}" == false ]]; then
        local http_code
        http_code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 2 ${auth_args[@]+"${auth_args[@]}"} "${health_url}" || echo "000")"
        if [[ "${http_code}" == "200" ]]; then
            local esc_serial esc_target payload curl_timeout
            esc_serial="$(json_escape "${DEVICE_SERIAL}")"
            esc_target="$(json_escape "${TARGET_HINT}")"
            payload="{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"android_navigate_to_node\",\"arguments\":{\"serial\":\"${esc_serial}\",\"target\":\"${esc_target}\",\"max_steps\":12,\"step_timeout_ms\":2000}}}"
            curl_timeout=$((DURATION_SEC + 4))

            echo "==> Triggering Layer 3 macro: navigate_to_node(\"${TARGET_HINT}\") on ${DEVICE_SERIAL}..."
            local resp
            resp="$(curl -sS --connect-timeout 2 --max-time "${curl_timeout}" -X POST "${mcp_url}" \
                -H "Content-Type: application/json" \
                ${auth_args[@]+"${auth_args[@]}"} \
                -d "${payload}" || true)"
            echo "==> MCP Response: ${resp}"
            if [[ "${resp}" == *'"isError":true'* || "${resp}" == *'"error":'* ]]; then
                echo "Warning: Layer 3 macro reported an error (recording continues)." >&2
            fi
            return 0
        elif [[ "${http_code}" == "401" ]]; then
            echo "Warning: MCP HTTP server at ${health_url} returned 401 Unauthorized. Pass --token or set ANDONMAC_MCP_TOKEN." >&2
        else
            echo "Note: AndOnMac MCP HTTP server not reachable at ${health_url} (HTTP ${http_code}; enable 'AI Agent Bridge (MCP)' in Menu Bar for zero-touch curl)."
        fi
    fi

    echo ">>> ACTION REQUIRED: Trigger the Layer 3 macro (e.g. hit your shortcut / run Navigate to '${TARGET_HINT}') NOW! <<<"
}

# ------------------------------------------------------------------------------
# Step 1: Record AndOnMac Window for 8 Seconds with screencapture -v
# ------------------------------------------------------------------------------
mkdir -p "$(dirname "${OUTPUT_GIF}")"

if [[ "${PICK_INTERACTIVE}" == true ]]; then
    echo "==> Click the AndOnMac window to start ${DURATION_SEC}s recording..."
    screencapture -v -x -i -w -V"${DURATION_SEC}" "${RAW_MP4}" &
    CAPTURE_PID=$!
    echo "==> Once you click the window, trigger your Layer 3 macro ('${TARGET_HINT}')!"
    wait "${CAPTURE_PID}"
    CAPTURE_PID=""
else
    echo "==> Starting ${DURATION_SEC}s recording of Window ID ${WINDOW_ID} -> ${RAW_MP4}..."
    screencapture -v -x -l"${WINDOW_ID}" -V"${DURATION_SEC}" "${RAW_MP4}" &
    CAPTURE_PID=$!

    # Brief settle so initial frame is captured before macro starts animating
    sleep 0.6
    trigger_layer3_macro

    echo "==> Waiting for ${DURATION_SEC}s capture to finish..."
    wait "${CAPTURE_PID}"
    CAPTURE_PID=""
fi

if [[ ! -s "${RAW_MP4}" ]]; then
    echo "Error: Screen recording failed or produced an empty file at ${RAW_MP4}." >&2
    exit 1
fi

if [[ "${KEEP_MP4}" == true ]]; then
    MP4_COPY="${OUTPUT_GIF%.gif}.mp4"
    cp "${RAW_MP4}" "${MP4_COPY}"
    echo "==> Saved raw recording copy to ${MP4_COPY}"
fi

# ------------------------------------------------------------------------------
# Step 2: Encode Highly Optimized < 5MB GIF via ffmpeg (palettegen + paletteuse)
# ------------------------------------------------------------------------------
encode_gif() {
    local max_w="$1"
    local fps="$2"
    local max_colors="$3"
    local bayer_scale="$4"

    local scale_filter="fps=${fps},scale='min(${max_w},iw)':-1:flags=lanczos"

    ffmpeg -y -v warning -i "${RAW_MP4}" \
        -vf "${scale_filter},palettegen=max_colors=${max_colors}:stats_mode=diff" \
        -frames:v 1 -update 1 "${PALETTE_PNG}"

    ffmpeg -y -v warning -i "${RAW_MP4}" -i "${PALETTE_PNG}" \
        -lavfi "${scale_filter} [x]; [x][1:v] paletteuse=dither=bayer:bayer_scale=${bayer_scale}:diff_mode=rectangle" \
        -loop 0 "${OUTPUT_GIF}"
}

echo "==> Generating custom palette and encoding GIF (max ${MAX_WIDTH}px, ${FPS}fps)..."
encode_gif "${MAX_WIDTH}" "${FPS}" 256 5

GIF_SIZE="$(wc -c < "${OUTPUT_GIF}" | tr -d ' ')"

# Adaptive fallback passes if the GIF exceeds 5MB
if [[ "${GIF_SIZE}" -ge "${MAX_GIF_BYTES}" ]]; then
    echo "==> Initial GIF is ${GIF_SIZE} bytes (>= 5MB); optimizing palette (128 colors)..."
    encode_gif "${MAX_WIDTH}" "${FPS}" 128 3
    GIF_SIZE="$(wc -c < "${OUTPUT_GIF}" | tr -d ' ')"
fi

if [[ "${GIF_SIZE}" -ge "${MAX_GIF_BYTES}" ]]; then
    echo "==> GIF is ${GIF_SIZE} bytes (>= 5MB); scaling down to 680px @ ${FPS}fps..."
    encode_gif 680 "${FPS}" 96 3
    GIF_SIZE="$(wc -c < "${OUTPUT_GIF}" | tr -d ' ')"
fi

if [[ "${GIF_SIZE}" -ge "${MAX_GIF_BYTES}" ]]; then
    echo "==> GIF is ${GIF_SIZE} bytes (>= 5MB); applying compact pass (600px @ 12fps, 64 colors)..."
    encode_gif 600 12 64 2
    GIF_SIZE="$(wc -c < "${OUTPUT_GIF}" | tr -d ' ')"
fi

GIF_SIZE_MB="$(awk "BEGIN { printf \"%.2f\", ${GIF_SIZE} / 1048576 }")"
echo "✅ Generated optimized demo GIF: ${OUTPUT_GIF} (${GIF_SIZE_MB} MiB / ${GIF_SIZE} bytes)"

if [[ "${GIF_SIZE}" -ge "${MAX_GIF_BYTES}" ]]; then
    echo "Warning: GIF still exceeds 5MB (${GIF_SIZE} bytes). Try reducing --duration." >&2
    exit 1
fi
