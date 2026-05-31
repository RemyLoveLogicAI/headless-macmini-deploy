#!/bin/bash
# uninstall.sh — Remove all headless deployment daemons and scripts
#
# Usage: sudo bash uninstall.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

if [ "$(id -u)" -ne 0 ]; then
    error "Run as sudo: sudo bash $0"
    exit 1
fi

info "Uninstalling headless deployment daemons..."

# Stop and remove memory watchdog
if launchctl list | grep -q "io.headless.memory-watchdog"; then
    info "Stopping memory watchdog..."
    launchctl bootout system /Library/LaunchDaemons/io.headless.memory-watchdog.plist 2>/dev/null || true
fi
rm -f /Library/LaunchDaemons/io.headless.memory-watchdog.plist
rm -f /usr/local/bin/memory-watchdog.sh
info "Memory watchdog removed"

# Stop and remove system guardian
if launchctl list | grep -q "io.headless.system-guardian"; then
    info "Stopping system guardian..."
    launchctl bootout system /Library/LaunchDaemons/io.headless.system-guardian.plist 2>/dev/null || true
fi
rm -f /Library/LaunchDaemons/io.headless.system-guardian.plist
rm -f /usr/local/bin/system-guardian.sh
info "System guardian removed"

# Clean up logs (keep for 30 days)
if [ -f /var/log/memory-watchdog.log ]; then
    warn "Log preserved: /var/log/memory-watchdog.log"
fi
if [ -f /var/log/system-guardian.log ]; then
    warn "Log preserved: /var/log/system-guardian.log"
fi

info "Uninstall complete. Manual settings NOT reverted:"
warn "  - FileVault: re-enable in System Settings → Privacy & Security"
warn "  - Auto-login: remove from System Settings → Users & Groups"
warn "  - Energy settings: reset in System Settings → Energy"
warn "  - Display sleep: re-enable if desired"
