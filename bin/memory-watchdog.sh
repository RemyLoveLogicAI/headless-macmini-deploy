#!/bin/bash
# memory-watchdog.sh — Proactive memory exhaustion monitor
#
# Polls macOS memory_pressure every POLL_INTERVAL seconds.
# When free memory drops below FREE_MEM_THRESHOLD_PERCENT AND swap usage
# indicates active thrashing, triggers a graceful reboot BEFORE the system
# freezes and drops remote connections.
#
# Install: sudo setup/install-watchdog.sh
# Logs:    /var/log/memory-watchdog.log
#
# Exit codes: 0 = healthy, 1 = critical (reboot triggered)

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
POLL_INTERVAL=300               # seconds between checks (5 min)
FREE_MEM_THRESHOLD_PERCENT=15   # reboot when free RAM < 15%
SWAP_USED_THRESHOLD_MB=2048     # AND swap used > 2GB (thrashing indicator)
LOG_FILE="/var/log/memory-watchdog.log"
HOSTNAME=$(hostname -s)

# ── Logging ────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] [$HOSTNAME] $*" | tee -a "$LOG_FILE"
}

# ── Metrics Collection ─────────────────────────────────────────────────────
# Returns free memory percentage via vm_stat
get_free_mem_percent() {
    local page_size free_pages total_pages
    page_size=$(pagesize)

    # vm_stat outputs in pages
    free_pages=$(vm_stat | awk '/Pages free/ {gsub(/\./, "", $3); print $3}')
    speculative_pages=$(vm_stat | awk '/Pages speculative/ {gsub(/\./, "", $3); print $3}')
    inactive_pages=$(vm_stat | awk '/Pages inactive/ {gsub(/\./, "", $3); print $3}')

    # Total physical memory in pages
    local total_mem_bytes
    total_mem_bytes=$(sysctl -n hw.memsize)
    total_pages=$((total_mem_bytes / page_size))

    # Free = free + speculative + inactive (all available for allocation)
    local available_pages=$((free_pages + speculative_pages + inactive_pages))
    echo $((available_pages * 100 / total_pages))
}

# Returns swap used in MB
get_swap_used_mb() {
    sysctl -n vm.swapusage 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/ && $(i-1) == "total") print int($i/1024/1024)}'
    # Fallback: parse "total: XXXX bytes" format
    sysctl -n vm.swapusage 2>/dev/null | grep -oP 'total: \K[0-9]+' | awk '{print int($1/1024/1024)}' 2>/dev/null || echo "0"
}

# Alternative: use memory_pressure command if available
get_memory_pressure_state() {
    if command -v memory_pressure &>/dev/null; then
        memory_pressure 2>/dev/null | grep -oP 'System-wide memory free percentage: \K[0-9]+' || echo ""
    fi
}

# ── Decision Logic ─────────────────────────────────────────────────────────
check_memory() {
    local free_pct swap_mb pressure_pct

    free_pct=$(get_free_mem_percent)
    swap_mb=$(get_swap_used_mb)
    pressure_pct=$(get_memory_pressure_state)

    log "INFO" "free_mem=${free_pct}% swap_used=${swap_mb}MB ${pressure_pct:+pressure_free=${pressure_pct}%}"

    # Primary trigger: free memory below threshold AND swap indicates thrashing
    if [ "$free_pct" -lt "$FREE_MEM_THRESHOLD_PERCENT" ] && [ "$swap_mb" -gt "$SWAP_USED_THRESHOLD_MB" ]; then
        log "CRITICAL" "Memory exhaustion imminent — free=${free_pct}% swap=${swap_mb}MB — initiating graceful reboot"
        return 1
    fi

    # Warning log: free memory low but swap not yet critical
    if [ "$free_pct" -lt "$FREE_MEM_THRESHOLD_PERCENT" ]; then
        log "WARN" "Free memory low (${free_pct}%) but swap usage moderate (${swap_mb}MB) — monitoring"
    fi

    return 0
}

# ── Graceful Reboot ────────────────────────────────────────────────────────
trigger_reboot() {
    log "CRITICAL" "Executing graceful reboot via shutdown -r now"

    # Notify via syslog for system log correlation
    logger -p daemon.crit "memory-watchdog: Initiating graceful reboot — free memory ${free_pct}% swap ${swap_mb}MB"

    # Small delay to ensure log flush
    sleep 2

    # Graceful reboot (not kill -9, not power cut)
    /sbin/shutdown -r now
}

# ── Main Loop ──────────────────────────────────────────────────────────────
main() {
    log "INFO" "Memory watchdog starting — threshold=${FREE_MEM_THRESHOLD_PERCENT}% swap_limit=${SWAP_USED_THRESHOLD_MB}MB interval=${POLL_INTERVAL}s"

    # Ensure log file permissions
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 644 "$LOG_FILE" 2>/dev/null || true

    while true; do
        if ! check_memory; then
            trigger_reboot
            # If shutdown somehow didn't execute, exit to let launchd restart us
            exit 1
        fi
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
