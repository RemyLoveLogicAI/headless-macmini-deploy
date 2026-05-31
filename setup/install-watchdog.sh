#!/bin/bash
# install-watchdog.sh — Install the memory watchdog daemon
#
# Usage: sudo bash install-watchdog.sh
#
# Installs:
#   /usr/local/bin/memory-watchdog.sh     — monitoring script
#   /Library/LaunchDaemons/io.headless.memory-watchdog.plist — service definition
#
# Verifies the daemon is running after install.

set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then
    error "Run as sudo: sudo bash $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DEST="/usr/local/bin/memory-watchdog.sh"
PLIST_SRC="$SCRIPT_DIR/launchd/io.headless.memory-watchdog.plist"
PLIST_DEST="/Library/LaunchDaemons/io.headless.memory-watchdog.plist"

# Step 1: Install script
info "Installing memory-watchdog.sh to $BIN_DEST"
cp "$SCRIPT_DIR/bin/memory-watchdog.sh" "$BIN_DEST"
chmod 755 "$BIN_DEST"
chown root:wheel "$BIN_DEST"

# Step 2: Install launchd plist
info "Installing LaunchDaemon plist to $PLIST_DEST"
cp "$PLIST_SRC" "$PLIST_DEST"
chmod 644 "$PLIST_DEST"
chown root:wheel "$PLIST_DEST"

# Step 3: Create log file
touch /var/log/memory-watchdog.log
chmod 644 /var/log/memory-watchdog.log

# Step 4: Load the daemon
info "Loading LaunchDaemon..."
launchctl bootout system "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DEST" 2>/dev/null || true

# Step 5: Verify
sleep 2
if launchctl list | grep -q "io.headless.memory-watchdog"; then
    info "Memory watchdog is running"
    info "Logs: tail -f /var/log/memory-watchdog.log"
else
    error "Failed to start memory watchdog"
    error "Check: cat /var/log/memory-watchdog.log"
    exit 1
fi

info "Installation complete"
