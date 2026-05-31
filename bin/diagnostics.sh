#!/bin/bash
# diagnostics.sh — Verify headless deployment health
#
# Usage: bash diagnostics.sh
#
# Checks:
#   1. FileVault status (should be OFF for headless)
#   2. Auto-login configuration
#   3. Energy settings (restartfreeze, restartpowerfailure, displaysleep)
#   4. Memory watchdog daemon status
#   5. System guardian daemon status
#   6. Jump Desktop Connect status
#   7. SSH / Screen Sharing status
#   8. Display detection (HDMI dummy dongle)
#   9. Current memory pressure
#   10. SwitchBot connectivity (if configured)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}PASS${NC}  $*"; }
fail()  { echo -e "  ${RED}FAIL${NC}  $*"; }
warn()  { echo -e "  ${YELLOW}WARN${NC}  $*"; }
header() { echo -e "\n${BLUE}=== $* ===${NC}"; }

ISSUES=0

header "FileVault"
FV_STATUS=$(fdesetup status 2>/dev/null || echo "Unknown")
if echo "$FV_STATUS" | grep -q "Off\|Disabled"; then
    pass "FileVault is OFF (required for headless auto-recovery)"
else
    warn "FileVault is ON — Jump Desktop will NOT work after reboot without physical unlock"
    warn "Current: $FV_STATUS"
fi

header "Auto Login"
AUTO_LOGIN_USER=$(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || echo "")
if [ -n "$AUTO_LOGIN_USER" ]; then
    pass "Auto-login enabled for: $AUTO_LOGIN_USER"
else
    warn "Auto-login not configured"
fi

header "Energy Settings"
restart_power=$(systemsetup -getrestartpowerfailure 2>/dev/null | grep -o "On\|Off" || echo "Unknown")
restart_freeze=$(systemsetup -getrestartfreeze 2>/dev/null | grep -o "On\|Off" || echo "Unknown")
display_sleep=$(systemsetup -getdisplaysleep 2>/dev/null || echo "Unknown")
system_sleep=$(systemsetup -getsleep 2>/dev/null || echo "Unknown")

[ "$restart_power" = "On" ] && pass "Restart after power failure: ON" || fail "Restart after power failure: OFF"
[ "$restart_freeze" = "On" ] && pass "Restart on freeze: ON" || fail "Restart on freeze: OFF"
if echo "$display_sleep" | grep -q "Off\|Never"; then
    pass "Display sleep: OFF"
else
    warn "Display sleep: $display_sleep (may cause GPU sleep issues)"
fi
if echo "$system_sleep" | grep -q "Off\|Never"; then
    pass "System sleep: OFF"
else
    warn "System sleep: $system_sleep (may disconnect remote sessions)"
fi

header "Daemons"
for daemon in "io.headless.memory-watchdog" "io.headless.system-guardian"; do
    if launchctl list | grep -q "$daemon"; then
        pass "$daemon: running"
    else
        fail "$daemon: NOT running"
        ISSUES=$((ISSUES + 1))
    fi
done

header "Scripts"
for script in "/usr/local/bin/memory-watchdog.sh" "/usr/local/bin/system-guardian.sh"; do
    if [ -f "$script" ] && [ -x "$script" ]; then
        pass "$script: exists and executable"
    else
        fail "$script: missing or not executable"
        ISSUES=$((ISSUES + 1))
    fi
done

header "Jump Desktop Connect"
if [ -d "/Applications/Jump Desktop Connect.app" ]; then
    pass "Jump Desktop Connect installed"
    # Check if running
    if pgrep -f "Jump Desktop Connect" > /dev/null 2>&1; then
        pass "Jump Desktop Connect: running"
    else
        warn "Jump Desktop Connect: NOT running"
    fi
else
    fail "Jump Desktop Connect: NOT installed"
    ISSUES=$((ISSUES + 1))
fi

header "Remote Access"
ssh_status=$(systemsetup -getremotelogin 2>/dev/null || echo "Unknown")
if echo "$ssh_status" | grep -q "On"; then
    pass "SSH: enabled"
else
    warn "SSH: disabled (no CLI fallback)"
fi

if launchctl list | grep -q "com.apple.screensharing"; then
    pass "Screen Sharing (VNC): enabled"
else
    warn "Screen Sharing (VNC): not loaded"
fi

header "Display"
display_count=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution" || echo "0")
if [ "$display_count" -gt 0 ]; then
    pass "Display detected ($display_count output(s))"
else
    warn "NO display detected — HDMI dummy dongle recommended"
fi

header "Memory Pressure"
page_size=$(pagesize)
total_mem=$(sysctl -n hw.memsize)
total_mem_gb=$((total_mem / 1024 / 1024 / 1024))

active=$(vm_stat | awk '/Pages active/ {gsub(/\./, "", $3); print $3}')
wired=$(vm_stat | awk '/Pages wired down/ {gsub(/\./, "", $3); print $3}')
free=$(vm_stat | awk '/Pages free/ {gsub(/\./, "", $3); print $3}')
inactive=$(vm_stat | awk '/Pages inactive/ {gsub(/\./, "", $3); print $3}')
speculative=$(vm_stat | awk '/Pages speculative/ {gsub(/\./, "", $3); print $3}')

total_pages=$((total_mem / page_size))
used_pct=$(((active + wired) * 100 / total_pages))
free_pct=$(((free + inactive + speculative) * 100 / total_pages))

swap_info=$(sysctl -n vm.swapusage 2>/dev/null || echo "")
swap_mb=$(echo "$swap_info" | grep -oP 'total: \K[0-9]+' | awk '{print int($1/1024/1024)}' 2>/dev/null || echo "0")

echo "  Total RAM: ${total_mem_gb} GB"
echo "  Used: ${used_pct}% | Available: ${free_pct}%"
echo "  Swap used: ${swap_mb} MB"

if [ "$free_pct" -lt 15 ]; then
    fail "FREE MEMORY CRITICAL: ${free_pct}% (threshold: 15%)"
    ISSUES=$((ISSUES + 1))
elif [ "$free_pct" -lt 30 ]; then
    warn "Free memory LOW: ${free_pct}%"
else
    pass "Free memory healthy: ${free_pct}%"
fi

header "Logs"
for logfile in "/var/log/memory-watchdog.log" "/var/log/system-guardian.log"; do
    if [ -f "$logfile" ]; then
        lines=$(wc -l < "$logfile" 2>/dev/null || echo "0")
        last_entry=$(tail -1 "$logfile" 2>/dev/null || echo "empty")
        pass "$logfile ($lines lines)"
        echo "    Latest: $last_entry"
    else
        warn "$logfile: not found (daemon may not have run yet)"
    fi
done

header "SwitchBot (Optional)"
if grep -q "YOUR_SECRET_TOKEN" /usr/local/bin/switchbot-reboot.sh 2>/dev/null; then
    warn "SwitchBot not configured — edit /usr/local/bin/switchbot-reboot.sh"
else
    pass "SwitchBot configured"
    # Test connectivity (non-destructive — just list devices)
    token=$(grep "SWITCHBOT_TOKEN=" /usr/local/bin/switchbot-reboot.sh | cut -d'"' -f2)
    if command -v curl &>/dev/null; then
        test_response=$(curl -s -o /dev/null -w "%{http_code}" \
            -H "Authorization: $token" \
            "https://api.switch-bot.com/v1.1/devices" 2>/dev/null || echo "000")
        if [ "$test_response" = "200" ]; then
            pass "SwitchBot API: reachable"
        else
            warn "SwitchBot API: unreachable (HTTP $test_response)"
        fi
    fi
fi

header "Summary"
if [ "$ISSUES" -eq 0 ]; then
    echo -e "  ${GREEN}All checks passed — system is configured for headless operation${NC}"
else
    echo -e "  ${RED}$ISSUES issue(s) found — review FAIL entries above${NC}"
fi
