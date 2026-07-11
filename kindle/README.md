# Kindle Setup

These scripts run on a jailbroken Kindle 4 (D01100) with the
[USBNetwork hack](https://www.mobileread.com/forums/showthread.php?t=88004) installed.

## Prerequisites

- Jailbroken Kindle 4
- USBNetwork hack installed (provides SSH access)
- SSH inbound allowed through the firewall (handled by `init-weather.sh`)

## Files

| File | Device path | Purpose |
|---|---|---|
| `display-weather.sh` | `/mnt/us/weather/display-weather.sh` | Main weather display script |
| `weather-secrets.sh` | `/mnt/us/weather/weather-secrets.sh` | Secret configuration (not in repo — see `weather-secrets.sh.example`) |
| `weather-image-error.png` | `/mnt/us/weather/weather-image-error.png` | Fallback image shown on download failure |

The startup script already exists on the device at `/etc/init.d/weather` and does not need to be copied.

## Installation

### 1. SSH into the Kindle

Connect via USB and SSH in:

```sh
ssh root@192.168.15.244
```

Or via WiFi once it is configured:

```sh
ssh root@<kindle-wifi-ip>
```

### 2. Create the weather folder

```sh
mkdir -p /mnt/us/weather
```

### 3. Copy the scripts

From a machine that can reach the device over HTTP (e.g. run `python3 -m http.server 3000` in the `kindle/` folder):

```sh
curl -o /mnt/us/weather/display-weather.sh http://<server-ip>:3000/display-weather.sh
chmod +x /mnt/us/weather/display-weather.sh
```

### 4. Create the secrets file

```sh
cat > /mnt/us/weather/weather-secrets.sh << 'EOF'
#!/bin/sh
IMG_URL="https://<your-cdn-or-s3-url>/weather.png"
TELE_URL="https://<api-id>.execute-api.<region>.amazonaws.com/prod/KindleBattery"
TELE_API_KEY="'x-api-key: <your-api-key>'"
EOF
chmod +x /mnt/us/weather/weather-secrets.sh
```

### 5. Update the startup script

Make the root filesystem writable, add the iptables SSH rule, then lock it back:

```sh
mntroot rw
vi /etc/init.d/weather
```

The `start)` block should look like:

```sh
  start)
    /usr/bin/ntpdate 192.168.30.1
    /etc/init.d/framework stop
    iptables -I INPUT -p tcp --dport 22 -j ACCEPT
    /mnt/us/weather/display-weather.sh >/dev/null 2>&1 &
  ;;
```

Then:

```sh
mntroot ro
```

## Behavior

- **On battery**: wakes at scheduled times (default 01:01 and 13:01), downloads the weather image, displays it, returns to deep sleep
- **USB/power connected**: within ~60 seconds the script detects external power, turns WiFi on, and keeps it on for SSH access. Scheduled downloads still run. When USB is unplugged, WiFi turns off and the device enters deep sleep
- **Maintenance**: plug in USB, wait ~60 seconds, SSH in via WiFi

## Updating scripts

With WiFi SSH active, pull the latest script directly from GitHub:

```sh
curl -o /mnt/us/weather/display-weather.sh http://<server-ip>:3000/display-weather.sh
chmod +x /mnt/us/weather/display-weather.sh
kill $(ps | grep display-weather | grep -v grep | awk '{print $1}') 2>/dev/null
/mnt/us/weather/display-weather.sh &
```

## Configuration

All configurable values are at the top of `display-weather.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `ACTION_TIME` | `"01:01 13:01"` | Scheduled download times (space-separated hh:mm, UTC) |
| `STAY_AWAKE` | `240` | Seconds before action time to stay awake |
| `WAKEUP_CHECK_DEFAULT` | `43200` | Default sleep interval in seconds (12h) |
| `NETWORK_TIMEOUT` | `60` | Seconds to wait for WiFi connection |
| `NTP_SERVER` | `0.pool.ntp.org` | NTP server for time sync |
