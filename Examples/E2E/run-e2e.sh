#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROJECT_PATH="$ROOT_DIR/Examples/E2E/BleuE2E.xcodeproj"
SCHEME="BleuE2E"
BUNDLE_ID="com.1amageek.bleu.e2e"
DERIVED_DATA_PATH="${BLEU_E2E_DERIVED_DATA:-$ROOT_DIR/.build/bleu-e2e-derived-data}"
RESULT_PATH="${BLEU_E2E_RESULT_PATH:-$ROOT_DIR/.build/bleu-e2e-result.json}"
LOG_DIR="${BLEU_E2E_LOG_DIR:-$ROOT_DIR/.build/bleu-e2e-logs}"
DEVELOPMENT_TEAM_VALUE="${DEVELOPMENT_TEAM:-88ACA86N96}"
IOS_DEVICE="${BLEU_E2E_IOS_DEVICE:-}"
CENTRAL_TIMEOUT_SECONDS="${BLEU_E2E_CENTRAL_TIMEOUT:-300}"
PERIPHERAL_WARMUP_SECONDS="${BLEU_E2E_PERIPHERAL_WARMUP:-5}"
READY_TIMEOUT_SECONDS="${BLEU_E2E_READY_TIMEOUT:-15}"
SCAN_TIMEOUT_SECONDS="${BLEU_E2E_SCAN_TIMEOUT:-8}"
SCAN_ATTEMPTS="${BLEU_E2E_SCAN_ATTEMPTS:-2}"
DIRECTION="${BLEU_E2E_DIRECTION:-both}"
ITERATIONS="${BLEU_E2E_ITERATIONS:-10}"
PAYLOAD_SIZES="${BLEU_E2E_PAYLOAD_SIZES:-16,182,183,244,512,1024}"
MINIMUM_PEER_COUNT="${BLEU_E2E_MINIMUM_PEER_COUNT:-1}"
RECONNECT_BETWEEN_ITERATIONS=0
RECONNECT_CYCLES="${BLEU_E2E_RECONNECT_CYCLES:-2}"
RECONNECT_PAYLOAD_SIZES="${BLEU_E2E_RECONNECT_PAYLOAD_SIZES:-16}"
SKIP_BUILD=0
MAC_PERIPHERAL_PID=""

usage() {
    cat <<USAGE
Usage: Examples/E2E/run-e2e.sh [options]

Options:
  --device <id>              iOS device UDID/name for devicectl and xcodebuild.
  --team <id>                Apple development team id. Defaults to DEVELOPMENT_TEAM or 88ACA86N96.
  --result <path>            Forward result JSON path. Reverse writes beside it with "-reverse".
  --direction <value>        forward, reverse, or both. Default: both.
  --iterations <count>       Central test iterations. Default: 10.
  --payload-sizes <csv>      Payload sizes for each iteration. Default: 16,182,183,244,512,1024.
  --minimum-peer-count <n>   Required discovered peer count. Default: 1.
  --scan-timeout <seconds>   Per-attempt scan timeout. Default: 8.
  --scan-attempts <count>    Scan attempts per iteration. Default: 2.
  --reconnect-cycles <count> Dedicated reconnect pass iterations. Default: 2.
  --reconnect-between-iterations
                             Also reconnect between every main soak iteration.
  --no-reconnect             Disable the dedicated reconnect pass.
  --skip-build               Reuse the existing DerivedData build products.
  --help                     Show this help.

Environment:
  BLEU_E2E_IOS_DEVICE          Same as --device.
  BLEU_E2E_RESULT_PATH         Same as --result.
  BLEU_E2E_DIRECTION           Same as --direction.
  BLEU_E2E_ITERATIONS          Same as --iterations.
  BLEU_E2E_PAYLOAD_SIZES       Same as --payload-sizes.
  BLEU_E2E_MINIMUM_PEER_COUNT  Same as --minimum-peer-count.
  BLEU_E2E_CENTRAL_TIMEOUT     Central run timeout in seconds.
  BLEU_E2E_PERIPHERAL_WARMUP   Seconds to wait after peripheral launch.
  BLEU_E2E_READY_TIMEOUT       App-side BLE actor system readiness timeout.
  BLEU_E2E_SCAN_TIMEOUT        Same as --scan-timeout.
  BLEU_E2E_SCAN_ATTEMPTS       Same as --scan-attempts.
  BLEU_E2E_RECONNECT_CYCLES    Same as --reconnect-cycles.
  BLEU_E2E_RECONNECT_PAYLOAD_SIZES
                                Payload sizes used for the dedicated reconnect pass. Default: 16.
  BLEU_E2E_DERIVED_DATA        DerivedData directory.
  BLEU_E2E_LOG_DIR             Command log directory.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device)
            IOS_DEVICE="${2:?Missing value for --device}"
            shift 2
            ;;
        --team)
            DEVELOPMENT_TEAM_VALUE="${2:?Missing value for --team}"
            shift 2
            ;;
        --result)
            RESULT_PATH="${2:?Missing value for --result}"
            shift 2
            ;;
        --direction)
            DIRECTION="${2:?Missing value for --direction}"
            shift 2
            ;;
        --iterations)
            ITERATIONS="${2:?Missing value for --iterations}"
            shift 2
            ;;
        --payload-sizes)
            PAYLOAD_SIZES="${2:?Missing value for --payload-sizes}"
            shift 2
            ;;
        --minimum-peer-count)
            MINIMUM_PEER_COUNT="${2:?Missing value for --minimum-peer-count}"
            shift 2
            ;;
        --scan-timeout)
            SCAN_TIMEOUT_SECONDS="${2:?Missing value for --scan-timeout}"
            shift 2
            ;;
        --scan-attempts)
            SCAN_ATTEMPTS="${2:?Missing value for --scan-attempts}"
            shift 2
            ;;
        --reconnect-cycles)
            RECONNECT_CYCLES="${2:?Missing value for --reconnect-cycles}"
            shift 2
            ;;
        --reconnect-between-iterations)
            RECONNECT_BETWEEN_ITERATIONS=1
            shift
            ;;
        --no-reconnect)
            RECONNECT_CYCLES=0
            RECONNECT_BETWEEN_ITERATIONS=0
            shift
            ;;
        --skip-build)
            SKIP_BUILD=1
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 64
            ;;
    esac
done

case "$DIRECTION" in
    forward|reverse|both)
        ;;
    *)
        echo "Invalid --direction: $DIRECTION" >&2
        usage >&2
        exit 64
        ;;
esac

mkdir -p "$DERIVED_DATA_PATH" "$LOG_DIR" "$(dirname "$RESULT_PATH")"

if [[ "$RESULT_PATH" == *.json ]]; then
    REVERSE_RESULT_PATH="${RESULT_PATH%.json}-reverse.json"
else
    REVERSE_RESULT_PATH="$RESULT_PATH-reverse.json"
fi
IOS_REVERSE_RESULT_FILE="$(basename "$REVERSE_RESULT_PATH")"

log_step() {
    printf '\n==> %s\n' "$1"
}

fail() {
    echo "E2E failed: $1" >&2
    exit "${2:-1}"
}

run_logged() {
    local name="$1"
    shift
    local log_path="$LOG_DIR/$name.log"

    log_step "$name"
    printf '+'
    printf ' %q' "$@"
    printf '\n'

    set +e
    "$@" 2>&1 | tee "$log_path"
    local status=${PIPESTATUS[0]}
    set -e

    return "$status"
}

detect_ios_device() {
    xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -showdestinations 2>/dev/null \
        | sed -nE '/platform:iOS, arch:/s/.*id:([^,]+), name:.*/\1/p' \
        | head -n 1
}

check_ios_lock_state() {
    run_logged preflight-ios-lock \
        xcrun devicectl \
        --timeout 15 \
        --json-output "$LOG_DIR/preflight-ios-lock.json" \
        device info lockState \
        --device "$IOS_DEVICE" \
        || fail "Unable to read iOS lock state. See $LOG_DIR/preflight-ios-lock.log" 66

    if grep -Eq '"unlockedSinceBoot"[[:space:]]*:[[:space:]]*false' "$LOG_DIR/preflight-ios-lock.json"; then
        fail "iOS device has not been unlocked since boot. Unlock it, keep it awake, and rerun this script." 66
    fi
}

automation_args() {
    local iterations="$1"
    local payload_sizes="$2"
    local reconnect="$3"
    local args=(
        --iterations "$iterations"
        --payload-sizes "$payload_sizes"
        --minimum-peer-count "$MINIMUM_PEER_COUNT"
        --scan-timeout "$SCAN_TIMEOUT_SECONDS"
        --scan-attempts "$SCAN_ATTEMPTS"
        --ready-timeout "$READY_TIMEOUT_SECONDS"
    )

    if [[ "$reconnect" -eq 1 ]]; then
        args+=(--reconnect-between-iterations)
    fi

    printf '%s\n' "${args[@]}"
}

assert_result_passed() {
    local name="$1"
    local path="$2"

    [[ -f "$path" ]] || fail "$name did not write result JSON at $path"

    log_step "$name-result-json"
    cat "$path"
    printf '\n'

    grep -Eq '"passed"[[:space:]]*:[[:space:]]*true' "$path" \
        || fail "$name reported failure. See $path"
}

result_path_with_suffix() {
    local base_path="$1"
    local suffix="$2"

    if [[ "$base_path" == *.json ]]; then
        printf '%s-%s.json\n' "${base_path%.json}" "$suffix"
    else
        printf '%s-%s.json\n' "$base_path" "$suffix"
    fi
}

cleanup() {
    if [[ -n "$MAC_PERIPHERAL_PID" ]] && kill -0 "$MAC_PERIPHERAL_PID" 2>/dev/null; then
        kill "$MAC_PERIPHERAL_PID" 2>/dev/null || true
        wait "$MAC_PERIPHERAL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

if [[ -z "$IOS_DEVICE" ]]; then
    IOS_DEVICE="$(detect_ios_device)"
fi

if [[ -z "$IOS_DEVICE" ]]; then
    fail "No connected physical iOS device was found. Connect one or pass --device." 65
fi

IOS_DESTINATION="platform=iOS,id=$IOS_DEVICE"
MAC_DESTINATION="platform=macOS"
IOS_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug-iphoneos/BleuE2E.app"
MAC_APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/BleuE2E.app"
MAC_EXECUTABLE="$MAC_APP_PATH/Contents/MacOS/BleuE2E"

rm -f "$RESULT_PATH" "$REVERSE_RESULT_PATH"

check_ios_lock_state

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    run_logged build-macos \
        xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -destination "$MAC_DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        CODE_SIGNING_ALLOWED=NO \
        build \
        || fail "macOS build failed. See $LOG_DIR/build-macos.log"

    run_logged build-ios-device \
        xcodebuild \
        -project "$PROJECT_PATH" \
        -scheme "$SCHEME" \
        -destination "$IOS_DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -allowProvisioningUpdates \
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_VALUE" \
        build \
        || fail "iOS device build failed. See $LOG_DIR/build-ios-device.log"
fi

[[ -d "$IOS_APP_PATH" ]] || fail "Missing iOS app at $IOS_APP_PATH"
[[ -x "$MAC_EXECUTABLE" ]] || fail "Missing macOS executable at $MAC_EXECUTABLE"

run_logged install-ios \
    xcrun devicectl \
    --timeout 120 \
    --json-output "$LOG_DIR/install-ios.json" \
    device install app \
    --device "$IOS_DEVICE" \
    "$IOS_APP_PATH" \
    || fail "iOS app install failed. See $LOG_DIR/install-ios.log"

run_macos_central_forward() {
    local name="$1"
    local result_path="$2"
    local iterations="$3"
    local payload_sizes="$4"
    local reconnect="$5"
    local args=()
    args=( $(automation_args "$iterations" "$payload_sizes" "$reconnect") )

    log_step "run-macos-central-$name"
    local central_command=(
        perl
        -e 'alarm shift; exec @ARGV'
        "$CENTRAL_TIMEOUT_SECONDS"
        "$MAC_EXECUTABLE"
        --role central
        --run-central
        --result-path "$result_path"
        --exit-after-run
        "${args[@]}"
    )
    printf '+'
    printf ' %q' "${central_command[@]}"
    printf '\n'

    set +e
    "${central_command[@]}" 2>&1 | tee "$LOG_DIR/run-macos-central-$name.log"
    local central_status=${PIPESTATUS[0]}
    set -e

    if [[ "$central_status" -ne 0 ]]; then
        fail "macOS central $name run failed with status $central_status. See $LOG_DIR/run-macos-central-$name.log and $result_path"
    fi

    assert_result_passed "$name" "$result_path"
}

launch_ios_peripheral() {
    local name="$1"

    set +e
    run_logged "launch-ios-peripheral-$name" \
        xcrun devicectl \
        --timeout 45 \
        --json-output "$LOG_DIR/launch-ios-peripheral-$name.json" \
        device process launch \
        --device "$IOS_DEVICE" \
        --terminate-existing \
        "$BUNDLE_ID" \
        --role peripheral \
        --start-peripheral \
        --ready-timeout "$READY_TIMEOUT_SECONDS"
    local launch_status=$?
    set -e

    if [[ "$launch_status" -ne 0 ]]; then
        if grep -q "Locked" "$LOG_DIR/launch-ios-peripheral-$name.log"; then
            fail "iOS device is locked. Unlock it, keep it awake, and rerun this script." 66
        fi
        fail "iOS peripheral launch failed. See $LOG_DIR/launch-ios-peripheral-$name.log"
    fi

    log_step "wait-for-ios-peripheral-$name"
    sleep "$PERIPHERAL_WARMUP_SECONDS"
}

run_forward_reconnect() {
    local cycle
    for cycle in $(seq 1 "$RECONNECT_CYCLES"); do
        launch_ios_peripheral "reconnect-$cycle"
        local result_path
        result_path="$(result_path_with_suffix "$RESULT_PATH" "forward-reconnect-$cycle")"
        run_macos_central_forward "forward-reconnect-$cycle" "$result_path" 1 "$RECONNECT_PAYLOAD_SIZES" 0
    done
}

run_forward() {
    launch_ios_peripheral "main"

    run_macos_central_forward "forward" "$RESULT_PATH" "$ITERATIONS" "$PAYLOAD_SIZES" "$RECONNECT_BETWEEN_ITERATIONS"

    if [[ "$RECONNECT_CYCLES" -gt 0 ]]; then
        run_forward_reconnect
    fi
}

start_macos_peripheral() {
    log_step "launch-macos-peripheral"
    printf '+ %q' "$MAC_EXECUTABLE"
    printf ' %q' --role peripheral --start-peripheral --ready-timeout "$READY_TIMEOUT_SECONDS"
    printf '\n'

    "$MAC_EXECUTABLE" \
        --role peripheral \
        --start-peripheral \
        --ready-timeout "$READY_TIMEOUT_SECONDS" \
        >"$LOG_DIR/launch-macos-peripheral.log" 2>&1 &
    MAC_PERIPHERAL_PID=$!

    log_step "wait-for-macos-peripheral"
    sleep "$PERIPHERAL_WARMUP_SECONDS"

    if ! kill -0 "$MAC_PERIPHERAL_PID" 2>/dev/null; then
        cat "$LOG_DIR/launch-macos-peripheral.log" >&2 || true
        fail "macOS peripheral exited before reverse run. See $LOG_DIR/launch-macos-peripheral.log"
    fi
}

run_ios_central_reverse() {
    local name="$1"
    local result_path="$2"
    local ios_result_file="$3"
    local iterations="$4"
    local payload_sizes="$5"
    local reconnect="$6"
    local args=()
    args=( $(automation_args "$iterations" "$payload_sizes" "$reconnect") )

    set +e
    run_logged "run-ios-central-$name" \
        xcrun devicectl \
        --timeout "$CENTRAL_TIMEOUT_SECONDS" \
        --json-output "$LOG_DIR/run-ios-central-$name.json" \
        device process launch \
        --device "$IOS_DEVICE" \
        --terminate-existing \
        --console \
        "$BUNDLE_ID" \
        --role central \
        --run-central \
        --result-path "$ios_result_file" \
        --exit-after-run \
        "${args[@]}"
    local ios_status=$?
    set -e

    if [[ "$ios_status" -ne 0 ]]; then
        if grep -q "Locked" "$LOG_DIR/run-ios-central-$name.log"; then
            fail "iOS device is locked. Unlock it, keep it awake, and rerun this script." 66
        fi
        fail "iOS central $name run failed with status $ios_status. See $LOG_DIR/run-ios-central-$name.log"
    fi

    run_logged "copy-ios-$name-result" \
        xcrun devicectl \
        --timeout 45 \
        --json-output "$LOG_DIR/copy-ios-$name-result.json" \
        device copy from \
        --device "$IOS_DEVICE" \
        --domain-type appDataContainer \
        --domain-identifier "$BUNDLE_ID" \
        --source "Documents/$ios_result_file" \
        --destination "$result_path" \
        || fail "Unable to copy iOS $name result. See $LOG_DIR/copy-ios-$name-result.log"

    assert_result_passed "$name" "$result_path"
}

stop_macos_peripheral() {
    if [[ -n "$MAC_PERIPHERAL_PID" ]] && kill -0 "$MAC_PERIPHERAL_PID" 2>/dev/null; then
        kill "$MAC_PERIPHERAL_PID" 2>/dev/null || true
        wait "$MAC_PERIPHERAL_PID" 2>/dev/null || true
    fi
    MAC_PERIPHERAL_PID=""
}

run_reverse_reconnect() {
    local cycle
    for cycle in $(seq 1 "$RECONNECT_CYCLES"); do
        stop_macos_peripheral
        start_macos_peripheral

        local result_path
        result_path="$(result_path_with_suffix "$RESULT_PATH" "reverse-reconnect-$cycle")"
        local ios_result_file
        ios_result_file="$(basename "$result_path")"
        run_ios_central_reverse "reverse-reconnect-$cycle" "$result_path" "$ios_result_file" 1 "$RECONNECT_PAYLOAD_SIZES" 0
    done
}

run_reverse() {
    start_macos_peripheral

    run_ios_central_reverse "reverse" "$REVERSE_RESULT_PATH" "$IOS_REVERSE_RESULT_FILE" "$ITERATIONS" "$PAYLOAD_SIZES" "$RECONNECT_BETWEEN_ITERATIONS"

    if [[ "$RECONNECT_CYCLES" -gt 0 ]]; then
        run_reverse_reconnect
    fi
}

case "$DIRECTION" in
    forward)
        run_forward
        ;;
    reverse)
        run_reverse
        ;;
    both)
        run_forward
        run_reverse
        ;;
esac

log_step "passed"
echo "Bleu macOS/iOS reliability E2E passed."
echo "Forward result: $RESULT_PATH"
if [[ "$RECONNECT_CYCLES" -gt 0 && ( "$DIRECTION" == "forward" || "$DIRECTION" == "both" ) ]]; then
    echo "Forward reconnect results: $(result_path_with_suffix "$RESULT_PATH" "forward-reconnect-*")"
fi
if [[ "$DIRECTION" == "reverse" || "$DIRECTION" == "both" ]]; then
    echo "Reverse result: $REVERSE_RESULT_PATH"
    if [[ "$RECONNECT_CYCLES" -gt 0 ]]; then
        echo "Reverse reconnect results: $(result_path_with_suffix "$RESULT_PATH" "reverse-reconnect-*")"
    fi
fi
