#!/bin/bash
# system-guardian.sh — Process priority protector for headless Mac mini
#
# Monitors memory pressure and selectively terminates low-priority processes
# before they trigger system-wide freeze. Protects Jump Desktop Connect at
# all costs — it is the sole remote management lifeline.
#
# Kill priority (first to die):
#   1. Google Drive (FileProviderEngines, com.google.drive.finder)
#   2. suggestd (macOS suggestion daemon — high memory, low value)
#   3. fileproviderd (file provider daemon — swells with Drive/Dropbox)
#   4. Docker Desktop (com.docker.hyperkit, com.docker.backend)
#   5. Chrome/Firefox renderer processes (if memory critical)
#
# Protected (never killed):
#   1. Jump Desktop Connect (com.jumpdesktop.flo)
#   2. Pieces OS (com.pieces.os)
#   3. opencode / Ghostty (terminal sessions)
#   4. sshd (remote shell access)
#
# Install: sudo setup/install-guardian.sh
# Logs:    /var/log/system-guardian.log

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────
POLL_INTERVAL=60                # seconds between checks (1 min)
MEMORY_PRESSURE_THRESHOLD=80    # kill procs when pressure > 80% (0-100 scale)
CRITICAL_THRESHOLD=90           # aggressive kill when pressure > 90%
LOG_FILE="/var/log/system-guardian.log"
HOSTNAME=$(hostname -s)

# ── Logging ────────────────────────────────────────────────────────────────
log() {
    local level="$1"; shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] [$HOSTNAME] $*" | tee -a "$LOG_FILE"
}

# ── Memory Pressure Calculation ───────────────────────────────────────────
# Returns 0-100 scale where 100 = total exhaustion
get_pressure_score() {
    local page_size total_pages used_pages
    page_size=$(pagesize)
    local total_mem_bytes
    total_mem_bytes=$(sysctl -n hw.memsize)
    total_pages=$((total_mem_bytes / page_size))

    local active inactive speculative free wired
    active=$(vm_stat | awk '/Pages active/ {gsub(/\./, "", $3); print $3}')
    inactive=$(vm_stat | awk '/Pages inactive/ {gsub(/\./, "", $3); print $3}')
    speculative=$(vm_stat | awk '/Pages speculative/ {gsub(/\./, "", $3); print $3}')
    free=$(vm_stat | awk '/Pages free/ {gsub(/\./, "", $3); print $3}')
    wired=$(vm_stat | awk '/Pages wired down/ {gsub(/\./, "", $3); print $3}')

    # Used = active + wired (cannot be reclaimed)
    used_pages=$((active + wired))
    echo $((used_pages * 100 / total_pages))
}

# ── Protected Process Check ───────────────────────────────────────────────
# Returns 0 if process is protected, 1 if safe to kill
is_protected() {
    local pid="$1"
    local bundle_id
    bundle_id=$(lsappinfo -all list only="bundleID" PID="$pid" 2>/dev/null | grep -o 'bundleID="[0-9A-Za-z._-]*"' | cut -d'"' -f2 || echo "")

    # Protected bundle IDs
    case "$bundle_id" in
        com.jumpdesktop*|com.pieces*|org.openssh.sshd|com.googlecode.iterm2|com.mitchellh.ghostty)
            return 0 ;;
    esac

    # Check if process name matches protected list
    local proc_name
    proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "")
    case "$proc_name" in
        sshd|Jump\ Desktop*|Pieces*|opencode|ghostty)
            return 0 ;;
    esac

    return 1
}

# ── Low-Priority Process Targets ──────────────────────────────────────────
# Ordered by kill priority — first match is killed first
get_kill_targets() {
    local targets=()

    # Tier 1: Sync daemons (highest memory, lowest user impact when killed)
    for pattern in "FileProviderEngines" "com.google.drive.finder" "com.dropbox.Client" "onedrive"; do
        local pids
        pids=$(pgrep -f "$pattern" 2>/dev/null || true)
        for pid in $pids; do
            if ! is_protected "$pid"; then
                targets+=("$pid:$pattern")
            fi
        done
    done

    # Tier 2: System suggestion daemons
    local suggestd_pids
    suggestd_pids=$(pgrep -x "suggestd" 2>/dev/null || true)
    for pid in $suggestd_pids; do
        targets+=("$pid:suggestd")
    done

    # Tier 3: File provider daemons
    local fpd_pids
    fpd_pids=$(pgrep -x "fileproviderd" 2>/dev/null || true)
    for pid in $fpd_pids; do
        if ! is_protected "$pid"; then
            targets+=("$pid:fileproviderd")
        fi
    done

    # Tier 4: Docker
    for pattern in "com.docker.hyperkit" "com.docker.backend" "Docker Desktop" "dockerd"; do
        local pids
        pids=$(pgrep -f "$pattern" 2>/dev/null || true)
        for pid in $pids; do
            if ! is_protected "$pid"; then
                targets+=("$pid:$pattern")
            fi
        done
    done

    printf '%s\n' "${targets[@]}"
}

# ── Kill Logic ─────────────────────────────────────────────────────────────
# Attempts SIGTERM first, then SIGKILL after 5s if process persists
kill_process() {
    local pid="$1" reason="$2"
    local proc_name
    proc_name=$(ps -p "$pid" -o comm= 2>/dev/null || echo "unknown")

    log "WARN" "Killing PID=$pid ($proc_name) — reason: $reason"

    # Graceful termination first
    kill -TERM "$pid" 2>/dev/null || true

    # Wait up to 5 seconds for graceful exit
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 5 ]; do
        sleep 1
        waited=$((waited + 1))
    done

    # Force kill if still alive
    if kill -0 "$pid" 2>/dev/null; then
        log "WARN" "Process PID=$pid did not exit gracefully — sending SIGKILL"
        kill -9 "$pid" 2>/dev/null || true
    fi

    log "INFO" "Terminated PID=$pid ($proc_name)"
}

# ── Main Check ─────────────────────────────────────────────────────────────
check_and_kill() {
    local pressure
    pressure=$(get_pressure_score)

    log "INFO" "Memory pressure: ${pressure}%"

    if [ "$pressure" -lt "$MEMORY_PRESSURE_THRESHOLD" ]; then
        return 0
    fi

    local threshold_label="elevated"
    if [ "$pressure" -ge "$CRITICAL_THRESHOLD" ]; then
        threshold_label="CRITICAL"
    fi

    log "WARN" "Memory pressure ${threshold_label} (${pressure}%) — seeking kill targets"

    local targets
    targets=$(get_kill_targets)

    if [ -z "$targets" ]; then
        log "WARN" "No kill targets found — system at risk"
        return 1
    fi

    local killed=0
    while IFS=: read -r pid reason; do
        [ -z "$pid" ] && continue
        kill_process "$pid" "$reason"
        killed=$((killed + 1))

        # Re-check pressure after each kill
        local new_pressure
        new_pressure=$(get_pressure_score)
        log "INFO" "Post-kill pressure: ${new_pressure}%"

        if [ "$new_pressure" -lt "$MEMORY_PRESSURE_THRESHOLD" ]; then
            log "INFO" "Pressure normalized after $killed kill(s) — stopping"
            return 0
        fi

        # At critical threshold, keep killing
        if [ "$pressure" -ge "$CRITICAL_THRESHOLD" ]; then
            continue
        fi

        # At elevated threshold, kill only 2 processes max
        if [ "$killed" -ge 2 ]; then
            log "WARN" "Killed 2 processes at elevated pressure — stopping"
            return 0
        fi
    done <<< "$targets"

    return 0
}

# ── Main Loop ──────────────────────────────────────────────────────────────
main() {
    log "INFO" "System guardian starting — pressure_threshold=${MEMORY_PRESSURE_THRESHOLD}% critical=${CRITICAL_THRESHOLD}% interval=${POLL_INTERVAL}s"

    touch "$LOG_FILE" 2>/dev/null || true
    chmod 644 "$LOG_FILE" 2>/dev/null || true

    while true; do
        check_and_kill || true
        sleep "$POLL_INTERVAL"
    done
}

main "$@"
