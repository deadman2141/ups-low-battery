#!/usr/bin/env bash
#
# ups_low_battery.sh - Poll NUT for UPS battery state; when it is critically
# low (or on battery with unknown charge), run SSH commands on remote
# systems (e.g. graceful shutdowns).
#
# Designed for Raspberry Pi OS (Bullseye/Bookworm). Requires NUT client:
#   sudo apt install nut-client   # provides upsc
#
# Safety properties:
#   * Fires the SSH commands only ONCE per power-loss event; resets the
#     trigger when the battery recovers above RECOVER_THRESHOLD.
#   * Also fires if the UPS is ON BATTERY (ups.status contains "OB") but
#     reports an unknown charge - many cheap units never report a number.
#   * Single-instance lock (flock) prevents double-firing from a second
#     copy of the script.
#   * A failing targets file or unreachable hosts NEVER kills the poll loop.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration (defaults - overridden by ups_low_battery.conf if present)
# ---------------------------------------------------------------------------
CONFIG_FILE="${CONFIG_FILE:-/etc/ups-low-battery/ups_low_battery.conf}"

UPS_NAME="nutdev1@localhost"        # NUT UPS name, e.g. "ups@localhost" or "cyberpower@192.168.1.50"
THRESHOLD=20                        # Fire when battery <= this (%)
RECOVER_THRESHOLD=50                # Reset trigger when battery >= this (%)
POLL_INTERVAL=10                    # Seconds between polls
SSH_TIMEOUT=15                      # SSH ConnectTimeout in seconds
STAGGER_DELAY=10                    # Seconds to wait after firing each host, giving it time
                                    # to begin shutting down before the next fires
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new"
LOG_TAG="ups_low_battery"
STATE_DIR="/var/lib/ups_low_battery"
TARGETS_FILE="/etc/ups-low-battery/ups_low_battery_targets"   # one "host command" per line

log() {
    # Write to stderr (journald) and syslog
    local msg="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >&2
    logger -t "$LOG_TAG" "$msg" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Back-compat: fall back to the legacy flat /etc/ locations (pre-migration
# installs) so an upgrade keeps working until the files are moved.
# ---------------------------------------------------------------------------
if [[ ! -f "$CONFIG_FILE" && -f /etc/ups_low_battery.conf ]]; then
    log "NOTE: using legacy config /etc/ups_low_battery.conf - move it to /etc/ups-low-battery/"
    CONFIG_FILE="/etc/ups_low_battery.conf"
fi

# ---------------------------------------------------------------------------
# Load config if present
# ---------------------------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# Back-compat: legacy targets location (only if we are still using the default)
if [[ "$TARGETS_FILE" == "/etc/ups-low-battery/ups_low_battery_targets" \
       && ! -f "$TARGETS_FILE" && -f /etc/ups_low_battery_targets ]]; then
    log "NOTE: using legacy targets file /etc/ups_low_battery_targets - move it to /etc/ups-low-battery/"
    TARGETS_FILE="/etc/ups_low_battery_targets"
fi

# ---------------------------------------------------------------------------
# Validate config - refuse to run (loudly) on nonsense values instead of
# dying mid-loop with an arithmetic error.
# ---------------------------------------------------------------------------
validate_config() {
    local v val bad=0
    for v in THRESHOLD RECOVER_THRESHOLD POLL_INTERVAL SSH_TIMEOUT; do
        eval "val=\${$v}"
        if [[ ! "${val:-}" =~ ^[0-9]+$ ]] || [[ "${val:-0}" -lt 1 ]]; then
            log "ERROR: $v must be a positive integer (got '${val:-}')"
            bad=1
        fi
    done
    if [[ ! "${STAGGER_DELAY:-}" =~ ^[0-9]+$ ]]; then
        log "ERROR: STAGGER_DELAY must be a non-negative integer (got '${STAGGER_DELAY:-}')"
        bad=1
    fi
    if [[ "$RECOVER_THRESHOLD" =~ ^[0-9]+$ && "$THRESHOLD" =~ ^[0-9]+$ ]] \
       && ! (( RECOVER_THRESHOLD > THRESHOLD )); then
        log "ERROR: RECOVER_THRESHOLD ($RECOVER_THRESHOLD) must be greater than THRESHOLD ($THRESHOLD)"
        bad=1
    fi
    if (( bad )); then
        log "ERROR: aborting - fix $CONFIG_FILE and restart the service"
        exit 1
    fi
}
validate_config

# ---------------------------------------------------------------------------
# State directory + single-instance lock (must come before any state writes)
# ---------------------------------------------------------------------------
STATE_FILE="${STATE_DIR}/triggered"

if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    log "ERROR: cannot create state dir $STATE_DIR - run install.sh or fix ownership for the service user"
    exit 1
fi

exec 9>"$STATE_DIR/.lock"
if ! flock -n 9; then
    log "Another instance of ups_low_battery is already running - exiting"
    exit 0
fi

# ---------------------------------------------------------------------------
# get_battery_charge -> prints integer percent; prints nothing on failure.
# Always returns 0 so set -e never kills the caller.
# ---------------------------------------------------------------------------
get_battery_charge() {
    local raw
    # Query the variable directly - upsc prints just the value:
    #   upsc ups@localhost battery.charge  ->  "98"
    raw="$(upsc "$UPS_NAME" battery.charge 2>/dev/null | tr -d ' %')" || raw=""
    # Fall back to parsing the full upsc listing ("battery.charge: 98")
    if [[ -z "${raw:-}" || "${raw,,}" == unknown* ]]; then
        raw="$(upsc "$UPS_NAME" 2>/dev/null | awk -F': ' '/^battery.charge:/ {print $2}' | tr -d ' %')" || raw=""
    fi
    # Validate numeric (allows trailing dot, e.g. "98.")
    if [[ "$raw" =~ ^[0-9]+(\.[0-9]*)?$ ]]; then
        echo "${raw%%.*}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# get_ups_status -> prints upsc ups.status (e.g. "OB OL"), empty on failure
# ---------------------------------------------------------------------------
get_ups_status() {
    upsc "$UPS_NAME" ups.status 2>/dev/null | head -n1 | tr -d '[:space:]' || true
}

# ---------------------------------------------------------------------------
# run_target - SSH into one host, run its command, one retry on failure.
# Captures SSH output for the log. Never returns non-zero (safe under set -e).
# ---------------------------------------------------------------------------
run_target() {
    local host="$1" cmd="$2" attempt out rc
    for attempt in 1 2; do
        rc=0
        # shellcheck disable=SC2086   # SSH_OPTS is intentionally word-split
        out="$(timeout $((SSH_TIMEOUT * 2)) ssh $SSH_OPTS \
               -o ConnectTimeout="$SSH_TIMEOUT" "$host" "$cmd" </dev/null 2>&1)" || rc=$?
        if (( rc == 0 )); then
            log "OK: $host ran '$cmd'"
            return 0
        fi
        log "WARN: $host attempt $attempt/2 failed (rc=$rc): ${out:-<no output>}"
    done
    log "ERROR: $host: giving up after 2 attempts - '$cmd' may NOT have run"
    return 0
}

# ---------------------------------------------------------------------------
# fire_targets - SSH into each target host, in file order, with STAGGER_DELAY
# seconds between hosts so each server can begin shutting down first
# ---------------------------------------------------------------------------
fire_targets() {
    if [[ ! -f "$TARGETS_FILE" ]]; then
        log "ERROR: targets file $TARGETS_FILE not found - nothing fired"
        return 0
    fi

    local line host cmd
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip blanks and comments (any whitespace, not just spaces)
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # A line with no whitespace has a host but no command
        if [[ ! "$line" =~ [[:space:]] ]]; then
            log "WARN: skipping line without a command: $line"
            continue
        fi
        host="${line%%[[:space:]]*}"
        cmd="${line#*[[:space:]]}"

        log "FIRING: ssh $host -> $cmd"
        run_target "$host" "$cmd"

        # Give this server time to shut down before moving on to the next
        if (( STAGGER_DELAY > 0 )); then
            sleep "$STAGGER_DELAY"
        fi
    done < "$TARGETS_FILE"

    return 0
}

# ---------------------------------------------------------------------------
# trigger_if_needed - fire all targets, but only if we haven't already
# ---------------------------------------------------------------------------
trigger_if_needed() {
    local reason="$1"
    if [[ -f "$STATE_FILE" ]]; then
        return 0
    fi
    log "CRITICAL: $reason - firing targets"
    touch "$STATE_FILE"
    fire_targets
    return 0
}

# ---------------------------------------------------------------------------
# Main poll loop
# ---------------------------------------------------------------------------
log "Started. UPS=${UPS_NAME} threshold=${THRESHOLD}% recover=${RECOVER_THRESHOLD}% poll=${POLL_INTERVAL}s"

prev_sig=""
warn_strikes=0

while true; do
    charge="$(get_battery_charge)"
    status="$(get_ups_status)"
    on_battery=0
    [[ "$status" == *OB* ]] && on_battery=1

    if [[ -n "$charge" ]]; then
        sig="charge=${charge}% status=${status:-unknown}"
    else
        sig="charge=UNKNOWN status=${status:-unreachable}"
    fi

    # Log each state transition once (plus a throttled warning when we
    # can't reach the UPS at all) - not every single poll.
    if [[ "$sig" != "$prev_sig" ]]; then
        log "UPS state: $sig"
        prev_sig="$sig"
        warn_strikes=0
    fi

    if [[ -n "$charge" ]]; then
        if (( charge <= THRESHOLD )); then
            trigger_if_needed "battery ${charge}% <= threshold ${THRESHOLD}%"
        elif (( charge >= RECOVER_THRESHOLD )); then
            if [[ -f "$STATE_FILE" ]]; then
                log "Battery recovered to ${charge}% (>= ${RECOVER_THRESHOLD}%) - resetting trigger"
                rm -f "$STATE_FILE"
            fi
        fi
    else
        if (( on_battery )); then
            # On battery but no numeric charge - fire anyway.
            trigger_if_needed "UPS is on battery with UNKNOWN charge (status: ${status})"
        else
            # UPS unreachable / charge unknown while on mains - warn at
            # most once every 12 polls instead of every poll.
            warn_strikes=$(( warn_strikes + 1 ))
            if (( warn_strikes % 12 == 1 )); then
                log "WARN: could not read battery.charge from $UPS_NAME (is upsd running?)"
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done
