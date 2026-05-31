#!/bin/bash
# setup-headless.sh — Configure macOS for unattended headless operation
#
# Must be run as: sudo bash setup-headless.sh
#
# This script:
#   1. Disables FileVault (required for pre-login network access)
#   2. Enables automatic login (bypasses login screen after reboot)
#   3. Configures Energy settings for auto-power-on after failure
#   4. Enables restartfreeze (firmware-level panic recovery)
#   5. Disasks display sleep (prevents GPU sleep killing remote desktop)
#   6. Verifies Jump Desktop Connect is set to launch at login
#
# WARNING: Disabling FileVault means physical theft = data accessible.
# Only deploy in physically secured locations.

set -euo pipefail

# ── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Root Check ─────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as sudo"
    echo "Usage: sudo bash $0"
    exit 1
fi

# ── Platform Check ─────────────────────────────────────────────────────────
ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
    warn "Not running on Apple Silicon (detected: $ARCH)"
    warn "Some settings may not apply correctly"
fi

info "Configuring headless Mac mini ($ARCH) for unattended operation"
echo "============================================================="

# ── Step 1: FileVault ─────────────────────────────────────────────────────
echo ""
info "Step 1: FileVault Status"

FV_STATUS=$(fdesetup status 2>/dev/null || echo "Unable to determine")
echo "  Current: $FV_STATUS"

if echo "$FV_STATUS" | grep -q "On"; then
    warn "FileVault is currently ON."
    warn "It must be disabled for headless auto-recovery to work."
    warn "Disabling FileVault will take 10-30 minutes to decrypt the drive."
    echo ""
    read -rp "  Disable FileVault now? (y/N): " confirm
    if [[ "$confirm" =~ ^[Yy] ]]; then
        info "Starting FileVault decryption..."
        fdesetup disable
        info "FileVault disable initiated. Decryption runs in background."
        info "The system will remain usable during decryption."
    else
        warn "FileVault NOT disabled. Jump Desktop will NOT work after reboot."
        warn "You will need to physically access the machine to unlock it."
    fi
else
    info "FileVault is already OFF or unavailable — OK"
fi

# ── Step 2: Auto Login ────────────────────────────────────────────────────
echo ""
info "Step 2: Automatic Login"

# Auto-login requires FileVault to be off. Check first.
if fdesetup status 2>/dev/null | grep -q "On"; then
    warn "Cannot enable auto-login while FileVault is ON."
    warn "Disable FileVault first, then re-run this script."
else
    # Get the list of users
    users=$(dscl . list /Users UniqueID | awk '$2 >= 500 && $2 < 65536 {print $1}' | grep -v "^_" | grep -v "daemon" | grep -v "nobody" || true)
    if [ -z "$users" ]; then
        warn "No standard user accounts found."
    else
        info "Available users: $users"
        echo ""
        read -rp "  Enter username for auto-login: " login_user
        if [ -n "$login_user" ]; then
            read -rsp "  Enter password for $login_user: " login_pass
            echo ""

            # Write auto-login plist
            defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser "$login_user"
            # Store password in keychain (macOS auto-login mechanism)
            security add-generic-password -a "$login_user" -s "com.apple.loginwindow" -w "$login_pass" /Library/Keychains/System.keychain 2>/dev/null || true

            info "Auto-login configured for user: $login_user"
        fi
    fi
fi

# ── Step 3: Energy Settings ───────────────────────────────────────────────
echo ""
info "Step 3: Energy Settings"

# Auto restart after power failure
info "Enabling auto restart after power failure..."
systemsetup -setrestartpowerfailure on 2>/dev/null || warn "Failed to set restartpowerfailure"

# Restart on freeze (firmware-level watchdog)
info "Enabling restart on system freeze..."
systemsetup -setrestartfreeze on 2>/dev/null || warn "Failed to set restartfreeze"

# Disable display sleep (prevents GPU sleep killing remote desktop)
info "Disabling display sleep..."
systemsetup -setdisplaysleep Off 2>/dev/null || warn "Failed to set displaysleep"

# Disable system sleep (keep network stack alive)
info "Disabling system sleep..."
systemsetup -setsleep Off 2>/dev/null || warn "Failed to set sleep"

# Disable hard disk sleep (keep SSD active for swap management)
info "Disabling hard disk sleep..."
systemsetup -setharddisksleep Off 2>/dev/null || warn "Failed to set harddisksleep"

info "Energy settings configured:"
systemsetup -getrestartpowerfailure 2>/dev/null || true
systemsetup -getrestartfreeze 2>/dev/null || true
systemsetup -getdisplaysleep 2>/dev/null || true
systemsetup -getsleep 2>/dev/null || true

# ── Step 4: Jump Desktop Connect ──────────────────────────────────────────
echo ""
info "Step 4: Jump Desktop Connect"

JD_PATH="/Applications/Jump Desktop Connect.app"
if [ -d "$JD_PATH" ]; then
    info "Jump Desktop Connect found."

    # Add to login items
    info "Adding Jump Desktop Connect to login items..."
    osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Jump Desktop Connect.app", hidden:false}' 2>/dev/null || warn "Failed to add login item (may require GUI)"

    # Enable remote management (Screen Sharing) as fallback
    info "Enabling Screen Sharing (VNC) as fallback..."
    launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true

    # Ensure SSH is enabled
    info "Checking SSH status..."
    if systemsetup -getremotelogin 2>/dev/null | grep -q "Off"; then
        warn "SSH is disabled. Enabling..."
        systemsetup -setremotelogin on 2>/dev/null || true
    else
        info "SSH is already enabled"
    fi
else
    warn "Jump Desktop Connect not found at $JD_PATH"
    warn "Install Jump Desktop Connect for remote access"
fi

# ── Step 5: HDMI Dummy Dongle Check ───────────────────────────────────────
echo ""
info "Step 5: Display Detection"

# Check if any display is connected
display_count=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution" || echo "0")
if [ "$display_count" -eq 0 ]; then
    warn "No display detected!"
    warn "Without a display, Jump Desktop may fail to encode video after reboot."
    warn "Recommendation: Plug in a $6 HDMI dummy dongle."
    warn "See: https://www.amazon.com/s?k=hdmi+dummy+plug"
else
    info "Display detected ($display_count output(s)) — OK"
fi

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "============================================================="
info "Headless configuration complete!"
echo ""
info "Next steps:"
echo "  1. Install memory watchdog:  sudo bash setup/install-watchdog.sh"
echo "  2. Install system guardian:  sudo bash setup/install-guardian.sh"
echo "  3. Reboot to verify:         sudo shutdown -r now"
echo ""
warn "After reboot, verify Jump Desktop Connect shows 'Online' from your iPad."
