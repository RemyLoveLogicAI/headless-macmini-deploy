# Deployment Guide — Headless Mac Mini M4

## Pre-Flight Checklist

- [ ] Mac mini M4 (2024) set up with macOS 15+ (Sequoia)
- [ ] Jump Desktop Connect installed from App Store
- [ ] Jump Desktop account logged in and host named
- [ ] HDMI dummy dongle plugged in (recommended, $6)
- [ ] SwitchBot Bot + Hub Mini purchased (optional, for hardware fail-safe)
- [ ] Mac mini placed on Satechi Stand or AODUKE wooden stand (if using SwitchBot)
- [ ] Physical location is secure (FileVault will be disabled)

## Phase 1: OS Configuration

```bash
# Clone or copy this package to the Mac mini
cd /path/to/headless-macmini

# Run the headless setup (MUST be sudo)
sudo bash setup/setup-headless.sh
```

This script will:
1. **Disable FileVault** (interactive prompt — confirm with `y`)
2. **Enable auto-login** (enter your username and password)
3. **Configure energy settings**:
   - Restart after power failure: ON
   - Restart on freeze: ON
   - Display sleep: OFF
   - System sleep: OFF
4. **Enable SSH and Screen Sharing** as fallback access
5. **Check for HDMI display** (warns if none detected)

**After setup, reboot to verify:**
```bash
sudo shutdown -r now
```

Wait 60-90 seconds, then verify Jump Desktop Connect shows "Online" from your iPad.

## Phase 2: Install Daemons

```bash
# Install memory watchdog (reboots at < 15% free memory)
sudo bash setup/install-watchdog.sh

# Install system guardian (kills low-priority procs before freeze)
sudo bash setup/install-guardian.sh
```

Both daemons run as root via launchd and start automatically on boot.

**Verify both are running:**
```bash
bash bin/diagnostics.sh
```

## Phase 3: SwitchBot Setup (Optional but Recommended)

### Hardware Mounting

**Option A: Satechi Stand & Hub**
1. Mount Mac mini M4 on Satechi stand
2. Adhere SwitchBot Bot to rear of stand, aligned with bottom cutout
3. Verify mechanical finger can reach power button through cutout

**Option B: AODUKE Wooden Stand**
1. Place Mac mini on AODUKE stand
2. Mount SwitchBot Bot on desk surface facing the front lever
3. SwitchBot presses the lever, lever presses the button

**Option C: Vertical Mount**
1. Place Mac mini on its side (fan exhaust pointing sideways)
2. Adhere SwitchBot Bot directly to desk beside the unit
3. Finger pushes laterally on exposed bottom plate

### Software Configuration

1. Open SwitchBot app on iPad/iPhone
2. Go to Profile → Settings → tap "App Version" 10 times → copy Token
3. Edit the SwitchBot script:
   ```bash
   sudo nano /usr/local/bin/switchbot-reboot.sh
   ```
4. Replace `YOUR_SECRET_TOKEN_HERE` and `YOUR_DEVICE_ID_HERE`
5. Test with a short press:
   ```bash
   sudo /usr/local/bin/switchbot-reboot.sh press
   ```

### Full Reboot Test

```bash
# This will force-shutdown and power-on the Mac mini
sudo /usr/local/bin/switchbot-reboot.sh full
```

Wait 60-90 seconds, then verify Jump Desktop Connect shows "Online."

## Phase 4: Validate the Full Stack

Run the diagnostics utility:

```bash
bash bin/diagnostics.sh
```

Expected output:
```
=== FileVault ===
  PASS  FileVault is OFF

=== Auto Login ===
  PASS  Auto-login enabled for: youruser

=== Energy Settings ===
  PASS  Restart after power failure: ON
  PASS  Restart on freeze: ON
  PASS  Display sleep: OFF
  PASS  System sleep: OFF

=== Daemons ===
  PASS  io.headless.memory-watchdog: running
  PASS  io.headless.system-guardian: running

=== Jump Desktop Connect ===
  PASS  Jump Desktop Connect installed
  PASS  Jump Desktop Connect: running

=== Display ===
  PASS  Display detected (1 output(s))

=== Memory Pressure ===
  PASS  Free memory healthy: 62%

=== Summary ===
  All checks passed
```

## Phase 5: Stress Test (Optional)

To verify the watchdog triggers correctly, simulate memory pressure:

```bash
# WARNING: This will trigger a reboot when memory drops below threshold
# Make sure all work is saved!

# Consume memory rapidly (adjust count based on your RAM)
# On a 16GB Mac mini, this creates ~14GB of memory pressure
python3 -c "
import time
data = []
chunk_size = 100 * 1024 * 1024  # 100MB chunks
while True:
    data.append(bytearray(chunk_size))
    time.sleep(0.5)
"
```

The system guardian should start killing low-priority processes first.
If pressure continues to rise, the memory watchdog will trigger a graceful reboot.

## Troubleshooting

### Jump Desktop shows "Offline" after reboot

1. **FileVault is still ON**: Disable it with `sudo fdesetup disable`
2. **Auto-login not configured**: Run `setup-headless.sh` again
3. **No display detected**: Plug in HDMI dummy dongle
4. **Jump Desktop Connect not in login items**:
   ```bash
   osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/Jump Desktop Connect.app", hidden:false}'
   ```

### Memory watchdog not running

```bash
# Check status
launchctl list | grep memory-watchdog

# Check logs
tail -f /var/log/memory-watchdog.log

# Reload
sudo launchctl bootout system /Library/LaunchDaemons/io.headless.memory-watchdog.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/io.headless.memory-watchdog.plist
```

### SwitchBot not responding

1. Verify Hub Mini is on same Wi-Fi network as Mac mini
2. Verify token is correct in `switchbot-reboot.sh`
3. Test API: `curl -H "Authorization: YOUR_TOKEN" https://api.switch-bot.com/v1.1/devices`
4. Check SwitchBot Bot battery level in app

### System still freezes before watchdog triggers

1. Reduce `FREE_MEM_THRESHOLD_PERCENT` from 15 to 20 in `memory-watchdog.sh`
2. Reduce `POLL_INTERVAL` from 300 to 120 for more frequent checks
3. Ensure system guardian is running (it should kill processes before watchdog needs to reboot)

## Uninstall

```bash
sudo bash setup/uninstall.sh
```

Note: This removes daemons and scripts only. Manual settings (FileVault, auto-login, energy) must be reverted in System Settings.
