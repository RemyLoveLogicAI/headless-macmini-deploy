# Headless Mac Mini M4 — Deployment Package

Production-grade tools for managing headless Apple Silicon Mac mini deployments
with remote power management and memory exhaustion fail-safes.

## Problem

When an M4 Mac mini exhausts RAM + swap (redline event), remote desktop tools
(Jump Desktop, Screen Sharing, SSH) lose connectivity. The bottom-mounted power
button makes physical recovery impractical for remote or rack-mounted units.

## Architecture

Three-layer defense:

```
Layer 1 — Prevention (proactive software)
├── memory-watchdog.sh    → graceful reboot before freeze
└── system-guardian.sh    → kill low-priority procs before redline

Layer 2 — Recovery (OS-level firmware)
├── setup-headless.sh     → FileVault off + auto-login + energy settings
└── systemsetup flags     → restartfreeze on + auto-power-on

Layer 3 — Hardware fail-safe (out-of-band)
├── switchbot-reboot.sh   → mechanical button press via SwitchBot API
└── Smart Plug (manual)   → AC power cycle (last resort)
```

## Quick Start

```bash
# 1. Configure OS for headless auto-recovery
sudo bash setup/setup-headless.sh

# 2. Install memory watchdog (reboots at 15% free memory)
sudo bash setup/install-watchdog.sh

# 3. Install system guardian (protects Jump Desktop from OOM)
sudo bash setup/install-guardian.sh

# 4. (Optional) Configure SwitchBot for hardware fail-safe
# Edit bin/switchbot-reboot.sh with your device ID and API credentials
```

## Layer Details

### Layer 1: Memory Watchdog

Polls `memory_pressure` every 5 minutes. When free memory drops below 15% AND
swap usage indicates thrashing, triggers `sudo shutdown -r now` for a clean
reboot — while the system still has resources to execute it gracefully.

- Script: `bin/memory-watchdog.sh`
- LaunchDaemon: `launchd/io.headless.memory-watchdog.plist`
- Install: `setup/install-watchdog.sh`

### Layer 2: System Guardian

Monitors memory pressure and selectively terminates low-priority processes
before they trigger a system-wide freeze. Protects Jump Desktop Connect at
all costs.

- Kill priority: Google Drive → suggestd → fileproviderd → Docker → browser tabs
- Protected: Jump Desktop Connect → Pieces OS → opencode → Ghostty
- Script: `bin/system-guardian.sh`
- LaunchDaemon: `launchd/io.headless.system-guardian.plist`
- Install: `setup/install-guardian.sh`

### Layer 3: Hardware Fail-Safe

When software layers fail and the system is completely frozen, the SwitchBot
integration provides mechanical button-press capability via Wi-Fi/BLE.

- Script: `bin/switchbot-reboot.sh`
- Requires: SwitchBot Hub Mini/Mac + SwitchBot Bot device
- Mount: Satechi Stand & Hub (rear cutout) or AODUKE wooden stand (front lever)

## Prerequisites

- macOS 15+ (Sequoia) on Apple Silicon Mac mini
- Jump Desktop installed and configured for auto-launch
- Administrator access (sudo)
- For SwitchBot: Hub Mini/Mac on same Wi-Fi network

## FileVault Warning

This package **disables FileVault** for headless auto-recovery. This means:
- Physical theft = data accessible
- Required for network stack + Jump Desktop to start before login
- Only deploy in physically secured locations

If FileVault cannot be disabled, use `sudo fdesetup authrestart` for planned
reboots only. This provides zero protection for spontaneous crashes.

## HDMI Dummy Dongle

For reliable Jump Desktop operation after reboot, a $6 HDMI dummy plug is
recommended. It prevents GPU sleep states that silently kill remote desktop
encoding. Without it, Jump Desktop may show "Initializing..." indefinitely.

## Logs

- Watchdog: `/var/log/memory-watchdog.log`
- Guardian: `/var/log/system-guardian.log`
- System: `log show --predicate 'subsystem == "io.headless"' --last 1h`

## Tested On

- Mac mini M4 (2024) — macOS 15.x Sequoia
- Mac mini M4 Pro (2024) — macOS 15.x Sequoia
