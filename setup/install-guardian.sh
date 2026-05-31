#!/bin/bash
# install-guardian.sh — Install the system guardian daemon
#
# Usage: sudo bash install-guardian.sh

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
BIN_DEST="/usr/local/bin/system-guardian.sh"
PLIST_DEST="/Library/LaunchDaemons/io.headless.system-guardian.plist"

info "Installing system-guardian.sh to $BIN_DEST"
cp "$SCRIPT_DIR/bin/system-guardian.sh" "$BIN_DEST"
chmod 755 "$BIN_DEST"
chown root:wheel "$BIN_DEST"

info "Installing LaunchDaemon plist"
cp "$SCRIPT_DIR/launchd/io.headless.system-guardian.plist" "$PLIST_DEST"
chmod 644 "$PLIST_DEST"
chown root:wheel "$PLIST_DEST"

touch /var/log/system-guardian.log
chmod 644 /var/log/system-guardian.log

info "Loading LaunchDaemon..."
launchctl bootout system "$PLIST_DEST" 2>/dev/null || true
launchctl bootstrap system "$PLIST_DEST" 2>/dev/null || true

sleep 2
if launchctl list | grep -q "io.headless.system-guardian"; then
    info "System guardian is running"
    info "Logs: tail -f /var/log/system-guardian.log"
else
    error "Failed to start system guardian"
    exit 1
fi

info "Installation complete"
