#!/bin/bash
# switchbot-reboot.sh — Hardware fail-safe reboot via SwitchBot
#
# Triggers a mechanical power button press on the Mac mini M4 using a
# SwitchBot Bot device connected via SwitchBot Hub Mini/Mac.
#
# Use when: Software watchdogs fail and the system is completely frozen.
# Requires: SwitchBot Hub on same network, SwitchBot Bot mounted near power button
#
# Setup:
#   1. Get your SwitchBot token: open SwitchBot app → Profile → Settings → Token
#   2. Find device ID: curl -H "Authorization: $SWITCHBOT_TOKEN" https://api.switch-bot.com/v1.1/devices
#   3. Edit this script with your token and device ID
#
# Usage:
#   ./switchbot-reboot.sh              # Press + hold 10s + release (full reboot)
#   ./switchbot-reboot.sh press        # Short press only
#   ./switchbot-reboot.sh hold 10      # Hold for N seconds

set -euo pipefail

# ── Configuration — EDIT THESE ─────────────────────────────────────────────
# Get from SwitchBot app: Profile → Preferences → App Version (tap 10 times) → Token
SWITCHBOT_TOKEN="YOUR_SECRET_TOKEN_HERE"
# Find via: curl -H "Authorization: $SWITCHBOT_TOKEN" https://api.switch-bot.com/v1.1/devices
SWITCHBOT_DEVICE_ID="YOUR_DEVICE_ID_HERE"
# ───────────────────────────────────────────────────────────────────────────

SWITCHBOT_API_URL="https://api.switch-bot.com/v1.1/devices"
LOG_FILE="/var/log/switchbot-reboot.log"

# ── Logging ────────────────────────────────────────────────────────────────
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ── SwitchBot API ──────────────────────────────────────────────────────────
# Send command to SwitchBot device
# Commands: "pressOn", "turnOn", "turnOff", "custom"
bot_command() {
    local command="$1"
    local parameter="${2:-default}"
    local body="{\"command\":\"$command\",\"parameter\":\"$parameter\",\"commandType\":\"command\"}"

    log "Sending command: $command (parameter: $parameter)"

    local response
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "$SWITCHBOT_API_URL/$SWITCHBOT_DEVICE_ID/commands" \
        -H "Authorization: $SWITCHBOT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$body" 2>/dev/null)

    local http_code
    http_code=$(echo "$response" | tail -1)
    local resp_body
    resp_body=$(echo "$response" | sed '$d')

    log "HTTP $http_code — $resp_body"

    if [ "$http_code" -ne 200 ]; then
        log "ERROR: API request failed with HTTP $http_code"
        return 1
    fi

    echo "$resp_body" | grep -q '"message":"success"' && return 0 || return 1
}

# ── Reboot Sequence ────────────────────────────────────────────────────────
# Full reboot: press and hold for force shutdown, wait, press again to power on
full_reboot() {
    local hold_duration="${1:-10}"

    log "=== Starting full hardware reboot sequence ==="

    # Step 1: Force shutdown (hold power button)
    log "Phase 1: Holding power button for ${hold_duration}s to force shutdown"
    bot_command "turnOn" "default" || { log "ERROR: Failed to initiate button press"; exit 1; }
    sleep "$hold_duration"

    # Step 2: Release (turn off)
    log "Phase 2: Releasing power button"
    bot_command "turnOff" "default" || { log "WARN: Release command failed — may already be released"; }
    sleep 5

    # Step 3: Power on (short press)
    log "Phase 3: Pressing power button to power on"
    bot_command "pressOn" "default" || { log "ERROR: Failed to power on"; exit 1; }

    log "=== Reboot sequence complete ==="
    log "Wait 60-90 seconds for macOS boot + Jump Desktop Connect to come online"
}

# Short press only
short_press() {
    log "Sending short press"
    bot_command "pressOn" "default"
}

# ── Main ───────────────────────────────────────────────────────────────────
case "${1:-full}" in
    full|reboot)
        full_reboot "${2:-10}"
        ;;
    press|short)
        short_press
        ;;
    hold)
        duration="${2:-10}"
        log "Holding power button for ${duration}s"
        bot_command "turnOn" "default"
        sleep "$duration"
        bot_command "turnOff" "default"
        ;;
    *)
        echo "Usage: $0 {full|press|hold} [duration_seconds]"
        echo ""
        echo "Commands:"
        echo "  full [10]    Full reboot cycle (hold $1s, release, press on) — default"
        echo "  press        Short press only"
        echo "  hold [10]    Hold power button for N seconds"
        echo ""
        echo "Before first use:"
        echo "  1. Edit this script with your SwitchBot token and device ID"
        echo "  2. Test with: $0 press"
        exit 1
        ;;
esac
