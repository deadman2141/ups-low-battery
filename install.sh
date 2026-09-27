#!/usr/bin/env bash
# install.sh - install the watchdog to a Raspberry Pi (run from a root shell
# or with sudo). Copies files, sets up systemd, does a one-shot sanity check.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Determine the service user from the unit file and verify it exists
# ---------------------------------------------------------------------------
SVC_USER="$(sed -n 's/^User=//p' "$SRC_DIR/ups-low-battery.service" | head -n1)"
SVC_USER="${SVC_USER:-root}"
if ! id "$SVC_USER" >/dev/null 2>&1; then
    echo "ERROR: service user '$SVC_USER' (from ups-low-battery.service) does not exist" >&2
    echo "       Fix the User= line in the unit file, then re-run this installer." >&2
    exit 1
fi

echo "==> Copying files"
install -m 0755 "$SRC_DIR/ups_low_battery.sh" /usr/local/bin/ups_low_battery.sh

# Everything etc-related now lives in its own directory
ETC_DIR=/etc/ups-low-battery
OLD_CONF=/etc/ups_low_battery.conf
OLD_TARGETS=/etc/ups_low_battery_targets
NEW_CONF=$ETC_DIR/ups_low_battery.conf
NEW_TARGETS=$ETC_DIR/ups_low_battery_targets
install -d -m 0755 "$ETC_DIR"

# Migrate an existing config from the old flat /etc/ location (if it's the only one)
if [[ -f "$OLD_CONF" && ! -f "$NEW_CONF" ]]; then
    install -m 0640 -o root -g "$SVC_USER" "$OLD_CONF" "$NEW_CONF"
    echo "    (migrated existing config from $OLD_CONF to $NEW_CONF)"
fi

# Back up an existing config before overwriting it
if [[ -f "$NEW_CONF" ]]; then
    cp -a "$NEW_CONF" "$NEW_CONF.bak.$(date +%Y%m%d%H%M%S)"
    echo "    (backed up existing $NEW_CONF)"
fi
install -m 0640 -o root -g "$SVC_USER" "$SRC_DIR/ups_low_battery.conf" "$NEW_CONF"

# Migrate an existing targets file from the old location (never overwrite the live one)
if [[ -f "$OLD_TARGETS" && ! -f "$NEW_TARGETS" ]]; then
    install -m 0640 -o root -g "$SVC_USER" "$OLD_TARGETS" "$NEW_TARGETS"
    echo "    (migrated existing targets to $NEW_TARGETS - you may delete $OLD_TARGETS)"
elif [[ ! -f "$NEW_TARGETS" ]]; then
    install -m 0640 -o root -g "$SVC_USER" \
        "$SRC_DIR/ups_low_battery_targets.example" "$NEW_TARGETS"
    echo "    (created $NEW_TARGETS from example - EDIT IT)"
fi

# The state dir MUST be writable by the service user, otherwise the script
# dies on 'mkdir' before its first poll (crash-loop under Restart=always).
install -d -m 0755 -o "$SVC_USER" -g "$SVC_USER" /var/lib/ups_low_battery

echo "==> Enabling service"
install -m 0644 "$SRC_DIR/ups-low-battery.service" /etc/systemd/system/ups-low-battery.service
systemctl daemon-reload
systemctl enable --now ups-low-battery.service

echo "==> Sanity check"
if ! command -v upsc >/dev/null; then
    echo "    WARNING: 'upsc' not found - run: sudo apt install nut-client"
else
    # Use the UPS name that is actually configured (strip surrounding quotes)
    UPS_NAME="$(sed -n 's/^UPS_NAME=//p' "$ETC_DIR/ups_low_battery.conf" | head -n1 | tr -d '\"')"
    if status_out="$(upsc "${UPS_NAME:-localhost}" ups.status 2>&1)"; then
        echo "    UPS OK: ${UPS_NAME} status = ${status_out}"
    else
        echo "    NOTE: UPS '${UPS_NAME}' is not responding yet (check /etc/nut/ups.conf, upsd, upsmon)"
        echo "    UPS names registered on the local upsd:"
        upsc -l 2>&1 | sed 's/^/      /' || true
    fi
fi

echo "==> Done. Follow the log with: sudo journalctl -u ups-low-battery -f"
