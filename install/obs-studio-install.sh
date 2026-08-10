#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Mcanon
# License: MIT | https://github.com/24dubstep/ProxmoxVE-Helper-Scripts/raw/main/LICENSE
# Source: https://obsproject.com/
# Source: https://github.com/Niek/obs-web
# Source: https://github.com/obsproject/obs-websocket
# Source: https://github.com/novnc/noVNC
# Source: https://github.com/LibVNC/x11vnc
# Source: https://github.com/canonical/lightdm
# Source: https://openbox.org/
# Source: https://www.nginx.com/

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ==============================================================================
# CONFIGURABLE VARIABLES
# ==============================================================================
OBS_RESOLUTION="${OBS_RESOLUTION:-1920x1080}"
OBS_FPS="${OBS_FPS:-30}"
OBS_DISPLAY="${OBS_DISPLAY:-:0}"
OBS_VNC_PORT="${OBS_VNC_PORT:-5900}"
OBS_NOVNC_PORT="${OBS_NOVNC_PORT:-8080}"
OBS_DASHBOARD_PORT="${OBS_DASHBOARD_PORT:-8888}"
OBS_WEBSOCKET_PORT="${OBS_WEBSOCKET_PORT:-4455}"

# Parse resolution
OBS_WIDTH="${OBS_RESOLUTION%x*}"
OBS_HEIGHT="${OBS_RESOLUTION#*x}"

# ==============================================================================
# DEPENDENCIES (LightDM, X11, Openbox, x11vnc, noVNC, OBS Studio, Nginx, etc.)
# ==============================================================================
msg_info "Installing Dependencies (LightDM, OBS Studio, X11, VNC, Nginx)"
$STD apt-get update
$STD apt-get install -y software-properties-common
$STD add-apt-repository -y universe
$STD add-apt-repository -y ppa:obsproject/obs-studio
$STD apt-get update

DEBIAN_FRONTEND=noninteractive $STD apt-get install -y \
  lightdm \
  lightdm-gtk-greeter \
  openbox \
  xvfb \
  x11vnc \
  novnc \
  websockify \
  dbus-x11 \
  ffmpeg \
  obs-studio \
  pulseaudio \
  alsa-utils \
  mesa-utils \
  libgl1-mesa-dri \
  libglx-mesa0 \
  nginx-light \
  jq \
  procps \
  curl \
  git \
  wget
msg_ok "Installed Dependencies"

# Set LightDM as default display manager non-interactively
echo "set shared/default-x-display-manager lightdm" | debconf-communicate 2>/dev/null || true
dpkg-reconfigure -f noninteractive lightdm 2>/dev/null || true

# ==============================================================================
# GPU PASSTHROUGH (VAAPI / NVENC)
# Disable automatic apt NVIDIA driver installation; custom driver is pushed via host script.
# ==============================================================================
export INSTALL_NVIDIA_DRIVERS="no"
setup_hwaccel

msg_info "Detecting GPU Encoder"
GPU_ENCODER="x264"
GPU_INFO="Software (x264)"

if [[ -e /dev/dri/renderD128 ]]; then
  if command -v vainfo &>/dev/null && vainfo 2>/dev/null | grep -qi "vaapi"; then
    GPU_ENCODER="vaapi"
    GPU_INFO="VAAPI (Intel/AMD GPU)"
  elif ls /dev/dri/renderD* &>/dev/null; then
    GPU_ENCODER="vaapi"
    GPU_INFO="VAAPI (GPU detected)"
  fi
fi

if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  GPU_ENCODER="nvenc"
  GPU_INFO="NVENC (NVIDIA GPU)"
fi

msg_ok "Detected GPU Encoder: ${GPU_INFO}"

# ==============================================================================
# LIGHTDM & X11 CONFIGURATION
# ==============================================================================
msg_info "Configuring LightDM & X11 Framebuffer"

mkdir -p /etc/lightdm/lightdm.conf.d

cat <<EOF >/etc/lightdm/lightdm.conf.d/50-headless-obs.conf
[Seat:*]
autologin-user=root
autologin-user-timeout=0
user-session=openbox
type=local
xserver-command=Xvfb ${OBS_DISPLAY} -screen 0 ${OBS_RESOLUTION}x24 +extension GLX +render -noreset
EOF

msg_ok "Configured LightDM & X11 Framebuffer"

# ==============================================================================
# OBS PROFILE & WEBSOCKET PRE-CONFIGURATION
# ==============================================================================
msg_info "Configuring OBS Studio Profile & WebSocket"

OBS_CONFIG="/root/.config/obs-studio"
OBS_PROFILE="${OBS_CONFIG}/basic/profiles/Headless"
OBS_SCENES="${OBS_CONFIG}/basic/scenes"
OBS_PLUGIN_WS="${OBS_CONFIG}/plugin_config/obs-websocket"

mkdir -p "${OBS_PROFILE}" "${OBS_SCENES}" "${OBS_PLUGIN_WS}" /root/recordings

# Determine encoder settings for profile
case "${GPU_ENCODER}" in
  vaapi)
    STREAM_ENCODER="ffmpeg_vaapi"
    RECORD_ENCODER="ffmpeg_vaapi"
    ;;
  nvenc)
    STREAM_ENCODER="jim_nvenc"
    RECORD_ENCODER="jim_nvenc"
    ;;
  *)
    STREAM_ENCODER="obs_x264"
    RECORD_ENCODER="obs_x264"
    ;;
esac

STREAM_TYPE_SETTING="StreamType=rtmp_common"
if [[ -f /etc/restreamer.env ]]; then
  STREAM_TYPE_SETTING="StreamType=rtmp_custom\nURL=rtmp://127.0.0.1:1935/live\nKey=stream"
fi

# basic.ini — OBS profile configuration
cat <<EOF >"${OBS_PROFILE}/basic.ini"
[General]
Name=Headless

[Video]
BaseCX=${OBS_WIDTH}
BaseCY=${OBS_HEIGHT}
OutputCX=${OBS_WIDTH}
OutputCY=${OBS_HEIGHT}
FPSType=0
FPSCommon=${OBS_FPS}

[Audio]
SampleRate=48000
ChannelSetup=Stereo

[Output]
Mode=Advanced

[AdvOut]
TrackIndex=1
RecType=Standard
RecFilePath=/root/recordings
RecFormat=mkv
RecEncoder=${RECORD_ENCODER}
StreamEncoder=${STREAM_ENCODER}
FFOutputToFile=true

[Stream]
$(echo -e "${STREAM_TYPE_SETTING}")
EOF

# Scene collection — default scene with display capture
cat <<'EOF' >"${OBS_SCENES}/Headless.json"
{
  "name": "Headless",
  "current_scene": "Main",
  "current_program_scene": "Main",
  "scene_order": [
    {"name": "Main"}
  ],
  "sources": [
    {
      "name": "Display Capture",
      "id": "xshm_input",
      "versioned_id": "xshm_input",
      "settings": {
        "screen": 0,
        "show_cursor": true,
        "advanced": false
      },
      "enabled": true
    }
  ],
  "scenes": [
    {
      "name": "Main",
      "items": [
        {
          "name": "Display Capture",
          "source_uuid": "",
          "visible": true,
          "locked": false,
          "pos": {"x": 0.0, "y": 0.0},
          "scale": {"x": 1.0, "y": 1.0},
          "bounds": {"x": 0.0, "y": 0.0},
          "crop": {"left": 0, "top": 0, "right": 0, "bottom": 0}
        }
      ]
    }
  ],
  "groups": [],
  "transitions": [
    {
      "name": "Cut",
      "id": "cut_transition"
    }
  ],
  "transition_duration": 300
}
EOF

# global.ini — disable first-run dialogs, enable obs-websocket port 4455 without auth
cat <<EOF >"${OBS_CONFIG}/global.ini"
[General]
FirstRun=false
LastVersion=503316480
EnableAutoUpdates=false

[BasicWindow]
geometry=AdnQywADAAAAAAAAAAAAAAeAAA8AAAgfAAAAAAAAAAAAB4APAAALAA==
DockState=000000ff00000000fd000000020000000000000100000002e4fc0100000001fb000000120073006300650006e006500730044006f0063006b0100000000000002e40000000000000000000000030000073f000000b6fc0100000001fb00000014006d006900780065007200440006f0063006b01000000000000073f0000000000000000000002e40000000000000004000000040000000800000008fc00000000
WarnBeforeStartingStream=false
WarnBeforeStoppingStream=false

[OBSWebSocket]
ServerEnabled=true
ServerPort=${OBS_WEBSOCKET_PORT}
AuthRequired=false

[Video]
BaseCX=${OBS_WIDTH}
BaseCY=${OBS_HEIGHT}
OutputCX=${OBS_WIDTH}
OutputCY=${OBS_HEIGHT}
EOF

# plugin config for obs-websocket
cat <<EOF >"${OBS_PLUGIN_WS}/config.json"
{
  "ServerEnabled": true,
  "ServerPort": ${OBS_WEBSOCKET_PORT},
  "AuthRequired": false
}
EOF

msg_ok "Configured OBS Studio Profile & WebSocket"

# ==============================================================================
# OPENBOX CONFIGURATION (auto-maximise OBS, no decorations)
# ==============================================================================
msg_info "Configuring Openbox Window Manager"

mkdir -p /root/.config/openbox

cat <<'EOF' >/root/.config/openbox/rc.xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc" xmlns:xi="http://www.w3.org/2001/XInclude">
<applications>
    <application class="obs" name="obs" type="normal">
      <decor>no</decor>
      <maximized>true</maximized>
      <focus>yes</focus>
      <layer>normal</layer>
    </application>
</applications>
<focus>
  <focusNew>yes</focusNew>
  <followMouse>no</followMouse>
  <focusLast>yes</focusLast>
  <underMouse>no</underMouse>
  <focusDelay>200</focusDelay>
  <raiseOnFocus>no</raiseOnFocus>
</focus>
<placement>
  <policy>Smart</policy>
  <center>yes</center>
</placement>
<desktops>
  <number>1</number>
  <firstdesk>1</firstdesk>
  <popupTime>0</popupTime>
</desktops>
<theme>
  <name>Clearlooks</name>
  <titleLayout>NLIMC</titleLayout>
</theme>
</openbox_config>
EOF

msg_ok "Configured Openbox Window Manager"

# ==============================================================================
# NOVNC & X11VNC DESKTOP ENVIRONMENT
# ==============================================================================
msg_info "Configuring VNC & noVNC Web Desktop"

ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# OBS Start Script
cat <<EOF >/usr/local/bin/start-obs-web.sh
#!/usr/bin/env bash
export DISPLAY=${OBS_DISPLAY}
export HOME=/root
export XDG_RUNTIME_DIR=/tmp/runtime-root
export QT_QPA_PLATFORM=xcb
export PULSE_SERVER=unix:/tmp/pulseaudio.socket

mkdir -p /tmp/runtime-root /tmp/.X11-unix /root/recordings
chmod 700 /tmp/runtime-root
chmod 1777 /tmp/.X11-unix

DISP_NUM="${OBS_DISPLAY#:}"
rm -f "/tmp/.X\${DISP_NUM}-lock" "/tmp/.X11-unix/X\${DISP_NUM}"

# Start virtual framebuffer if LightDM/Xorg isn't running
if ! pgrep -f "Xvfb|Xorg|lightdm" >/dev/null; then
  Xvfb ${OBS_DISPLAY} -screen 0 ${OBS_RESOLUTION}x24 +extension GLX +render -noreset &
  sleep 2
fi

# Start PulseAudio
if ! pgrep -x pulseaudio >/dev/null; then
  pulseaudio --start --exit-idle-time=-1 2>/dev/null || true
  sleep 1
fi

# Start Openbox
if ! pgrep -x openbox >/dev/null; then
  openbox &
  sleep 1
fi

# Start x11vnc
if ! pgrep -f "x11vnc" >/dev/null; then
  x11vnc -display ${OBS_DISPLAY} -forever -shared -nopw -rfbport ${OBS_VNC_PORT} -bg -o /var/log/x11vnc.log 2>/dev/null || true
  sleep 1
fi

# Start websockify / noVNC
if ! pgrep -f "websockify" >/dev/null; then
  websockify --web /usr/share/novnc ${OBS_NOVNC_PORT} localhost:${OBS_VNC_PORT} &
  sleep 1
fi

# Launch OBS Studio in persistent monitor loop
while true; do
  if ! pgrep -f "bin/obs" >/dev/null && ! pgrep -x obs >/dev/null; then
    obs --profile "Headless" --collection "Headless" --startstreaming >>/var/log/obs-studio.log 2>&1 || \
    obs --profile "Headless" --collection "Headless" >>/var/log/obs-studio.log 2>&1 || \
    obs >>/var/log/obs-studio.log 2>&1
  fi
  sleep 3
done
EOF
chmod +x /usr/local/bin/start-obs-web.sh

msg_ok "Configured VNC & noVNC Web Desktop"

# ==============================================================================
# STATUS DASHBOARD & OBS-WEB CONTROL PANEL (PORT 8888)
# ==============================================================================
msg_info "Setting up OBS Web Dashboard & Control Panel"

mkdir -p /var/www/obs-dashboard /var/www/obs-dashboard/api /var/www/obs-dashboard/obs-web

# Fetch Niek's pre-built OBS-Web frontend (gh-pages)
if command -v git >/dev/null 2>&1; then
  git clone --depth 1 -b gh-pages https://github.com/Niek/obs-web.git /var/www/obs-dashboard/obs-web 2>/dev/null || true
fi

if [[ ! -f /var/www/obs-dashboard/obs-web/index.html ]]; then
  mkdir -p /tmp/obs-web-dl
  curl -fsSL https://github.com/Niek/obs-web/archive/refs/heads/gh-pages.tar.gz -o /tmp/obs-web.tar.gz 2>/dev/null || true
  if [[ -f /tmp/obs-web.tar.gz ]]; then
    tar -xzf /tmp/obs-web.tar.gz -C /tmp/obs-web-dl --strip-components=1 2>/dev/null || true
    cp -r /tmp/obs-web-dl/* /var/www/obs-dashboard/obs-web/ 2>/dev/null || true
    rm -rf /tmp/obs-web-dl /tmp/obs-web.tar.gz
  fi
fi

# Status update script (called by cron and on-demand)
cat <<'STATUSEOF' >/usr/local/bin/obs-status-update.sh
#!/usr/bin/env bash
# Generates /var/www/obs-dashboard/api/status.json

OBS_PID=$(pgrep -f "bin/obs" 2>/dev/null | head -n1)
if [[ -z "${OBS_PID}" ]]; then
  OBS_PID=$(pgrep -x obs 2>/dev/null | head -n1 || echo "")
fi
OBS_STATUS="stopped"
OBS_UPTIME=""

if [[ -n "${OBS_PID}" ]]; then
  OBS_STATUS="running"
  OBS_UPTIME=$(ps -p "${OBS_PID}" -o etime= 2>/dev/null | xargs)
fi

# GPU info
GPU_INFO="None detected"
GPU_ENCODER="x264"
if [[ -e /dev/dri/renderD128 ]]; then
  GPU_INFO="GPU device available (/dev/dri/renderD128)"
  GPU_ENCODER="vaapi"
fi
if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  GPU_INFO=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null || echo "NVIDIA GPU")
  GPU_ENCODER="nvenc"
fi

# System resources
CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "0")
MEM_TOTAL=$(free -m | awk '/Mem:/{print $2}' 2>/dev/null || echo "0")
MEM_USED=$(free -m | awk '/Mem:/{print $3}' 2>/dev/null || echo "0")
DISK_USAGE=$(df -h /root/recordings 2>/dev/null | awk 'NR==2{print $5}' || echo "N/A")

# VNC & LightDM status
VNC_STATUS="stopped"
if pgrep -f "x11vnc" &>/dev/null; then
  VNC_STATUS="running"
fi

LIGHTDM_STATUS="stopped"
if pgrep -f "Xvfb|Xorg|lightdm" &>/dev/null; then
  LIGHTDM_STATUS="running"
fi

CONTAINER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "unknown")

cat <<JSONEOF >/var/www/obs-dashboard/api/status.json
{
  "obs": {
    "status": "${OBS_STATUS}",
    "pid": "${OBS_PID}",
    "uptime": "${OBS_UPTIME}",
    "websocket_port": 4455
  },
  "gpu": {
    "info": "${GPU_INFO}",
    "encoder": "${GPU_ENCODER}"
  },
  "system": {
    "cpu_usage": "${CPU_USAGE}",
    "memory_total_mb": ${MEM_TOTAL},
    "memory_used_mb": ${MEM_USED},
    "disk_recordings": "${DISK_USAGE}"
  },
  "services": {
    "lightdm": "${LIGHTDM_STATUS}",
    "vnc": "${VNC_STATUS}",
    "novnc_url": "http://${CONTAINER_IP}:8080"
  },
  "timestamp": "$(date -Iseconds)"
}
JSONEOF
STATUSEOF
chmod +x /usr/local/bin/obs-status-update.sh

# Combined Dashboard HTML (System Status + OBS Control Links + WebSocket Controller)
cat <<'HTMLEOF' >/var/www/obs-dashboard/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>OBS Studio — Headless Dashboard</title>
  <style>
    :root {
      --bg-primary: #0d1117;
      --bg-card: #161b22;
      --bg-card-hover: #1c2129;
      --border: #30363d;
      --text-primary: #e6edf3;
      --text-secondary: #8b949e;
      --accent-green: #3fb950;
      --accent-red: #f85149;
      --accent-blue: #58a6ff;
      --accent-purple: #bc8cff;
      --accent-orange: #d29922;
      --gradient-primary: linear-gradient(135deg, #58a6ff 0%, #bc8cff 100%);
    }
    * { margin: 0; padding: 0; box-sizing: border-box; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
      background: var(--bg-primary);
      color: var(--text-primary);
      min-height: 100vh;
      padding: 24px;
    }
    .header {
      text-align: center;
      margin-bottom: 32px;
      padding: 24px;
      background: var(--bg-card);
      border: 1px solid var(--border);
      border-radius: 12px;
    }
    .header h1 {
      font-size: 28px;
      font-weight: 600;
      background: var(--gradient-primary);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
      margin-bottom: 8px;
    }
    .header p { color: var(--text-secondary); font-size: 14px; }
    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 16px;
      max-width: 1200px;
      margin: 0 auto;
    }
    .card {
      background: var(--bg-card);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 20px;
      transition: background 0.2s, border-color 0.2s;
    }
    .card:hover {
      background: var(--bg-card-hover);
      border-color: var(--accent-blue);
    }
    .card-title {
      font-size: 13px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      color: var(--text-secondary);
      margin-bottom: 16px;
      display: flex;
      align-items: center;
      gap: 8px;
    }
    .card-title .icon { font-size: 16px; }
    .status-row {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 8px 0;
      border-bottom: 1px solid var(--border);
    }
    .status-row:last-child { border-bottom: none; }
    .status-label { color: var(--text-secondary); font-size: 14px; }
    .status-value { font-weight: 500; font-size: 14px; }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 6px;
      padding: 4px 10px;
      border-radius: 20px;
      font-size: 12px;
      font-weight: 600;
    }
    .badge-green {
      background: rgba(63, 185, 80, 0.15);
      color: var(--accent-green);
      border: 1px solid rgba(63, 185, 80, 0.3);
    }
    .badge-red {
      background: rgba(248, 81, 73, 0.15);
      color: var(--accent-red);
      border: 1px solid rgba(248, 81, 73, 0.3);
    }
    .badge-blue {
      background: rgba(88, 166, 255, 0.15);
      color: var(--accent-blue);
      border: 1px solid rgba(88, 166, 255, 0.3);
    }
    .badge::before {
      content: '';
      width: 8px;
      height: 8px;
      border-radius: 50%;
      display: inline-block;
    }
    .badge-green::before { background: var(--accent-green); }
    .badge-red::before { background: var(--accent-red); }
    .badge-blue::before { background: var(--accent-blue); }
    .progress-bar {
      width: 100%;
      height: 6px;
      background: var(--border);
      border-radius: 3px;
      margin-top: 4px;
    }
    .progress-fill {
      height: 100%;
      border-radius: 3px;
      background: var(--gradient-primary);
      transition: width 0.5s ease;
    }
    .link-btn {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 10px 20px;
      border-radius: 8px;
      text-decoration: none;
      font-size: 14px;
      font-weight: 500;
      transition: all 0.2s;
      border: 1px solid var(--border);
      color: var(--text-primary);
      background: var(--bg-primary);
    }
    .link-btn:hover {
      border-color: var(--accent-blue);
      background: rgba(88, 166, 255, 0.1);
    }
    .link-btn.primary {
      background: var(--accent-blue);
      color: #fff;
      border-color: var(--accent-blue);
    }
    .link-btn.primary:hover { opacity: 0.9; }
    .links { display: flex; gap: 12px; flex-wrap: wrap; margin-top: 12px; }
    .refresh-info {
      text-align: center;
      margin-top: 24px;
      color: var(--text-secondary);
      font-size: 12px;
    }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
    .loading { animation: pulse 1.5s infinite; }
  </style>
</head>
<body>
  <div class="header">
    <h1>🎬 OBS Studio — Headless Control Panel</h1>
    <p>Proxmox LXC Container Management Dashboard</p>
  </div>

  <div class="grid">
    <!-- OBS Status -->
    <div class="card">
      <div class="card-title"><span class="icon">📡</span> OBS Studio</div>
      <div class="status-row">
        <span class="status-label">Status</span>
        <span id="obs-status" class="badge badge-red loading">Loading...</span>
      </div>
      <div class="status-row">
        <span class="status-label">PID</span>
        <span id="obs-pid" class="status-value">—</span>
      </div>
      <div class="status-row">
        <span class="status-label">Uptime</span>
        <span id="obs-uptime" class="status-value">—</span>
      </div>
      <div class="status-row">
        <span class="status-label">WebSocket Port</span>
        <span id="obs-ws-port" class="status-value">4455</span>
      </div>
    </div>

    <!-- GPU & Encoder -->
    <div class="card">
      <div class="card-title"><span class="icon">🎮</span> GPU & Encoder</div>
      <div class="status-row">
        <span class="status-label">GPU</span>
        <span id="gpu-info" class="status-value">—</span>
      </div>
      <div class="status-row">
        <span class="status-label">Encoder</span>
        <span id="gpu-encoder" class="badge badge-blue">—</span>
      </div>
    </div>

    <!-- System Resources -->
    <div class="card">
      <div class="card-title"><span class="icon">⚙️</span> System Resources</div>
      <div class="status-row">
        <span class="status-label">CPU Usage</span>
        <span id="cpu-usage" class="status-value">—</span>
      </div>
      <div class="status-row" style="flex-direction: column; align-items: stretch;">
        <div style="display: flex; justify-content: space-between;">
          <span class="status-label">Memory</span>
          <span id="mem-info" class="status-value">—</span>
        </div>
        <div class="progress-bar">
          <div id="mem-bar" class="progress-fill" style="width: 0%;"></div>
        </div>
      </div>
      <div class="status-row">
        <span class="status-label">Recordings Disk</span>
        <span id="disk-usage" class="status-value">—</span>
      </div>
    </div>

    <!-- Quick Actions & Links -->
    <div class="card">
      <div class="card-title"><span class="icon">🔗</span> Remote Control & Interfaces</div>
      <div class="status-row">
        <span class="status-label">LightDM / X11</span>
        <span id="lightdm-status" class="badge badge-red loading">Loading...</span>
      </div>
      <div class="status-row">
        <span class="status-label">VNC Server</span>
        <span id="vnc-status" class="badge badge-red loading">Loading...</span>
      </div>
      <div class="links">
        <a id="obsweb-link" href="/obs-web/" target="_blank" class="link-btn primary">🎛️ Open OBS Web Remote Control</a>
        <a id="restreamer-link" href="#" target="_blank" class="link-btn primary">📡 Open Restreamer Interface</a>
        <a id="novnc-link" href="#" target="_blank" class="link-btn">🖥️ Open noVNC Desktop</a>
        <a href="/api/status.json" target="_blank" class="link-btn">📊 System Status API</a>
      </div>
    </div>
  </div>

  <div class="refresh-info">
    Auto-refresh every 10 seconds · Last update: <span id="last-update">—</span>
  </div>

  <script>
    async function fetchStatus() {
      try {
        const res = await fetch('/api/status.json?_=' + Date.now());
        const d = await res.json();

        // OBS
        const obsEl = document.getElementById('obs-status');
        obsEl.className = d.obs.status === 'running' ? 'badge badge-green' : 'badge badge-red';
        obsEl.textContent = d.obs.status === 'running' ? '● Running' : '● Stopped';
        document.getElementById('obs-pid').textContent = d.obs.pid || '—';
        document.getElementById('obs-uptime').textContent = d.obs.uptime || '—';
        document.getElementById('obs-ws-port').textContent = d.obs.websocket_port || 4455;

        // GPU
        document.getElementById('gpu-info').textContent = d.gpu.info;
        const encEl = document.getElementById('gpu-encoder');
        encEl.textContent = d.gpu.encoder.toUpperCase();

        // System
        document.getElementById('cpu-usage').textContent = d.system.cpu_usage + '%';
        const memPct = d.system.memory_total_mb > 0
          ? Math.round((d.system.memory_used_mb / d.system.memory_total_mb) * 100) : 0;
        document.getElementById('mem-info').textContent =
          d.system.memory_used_mb + ' / ' + d.system.memory_total_mb + ' MB (' + memPct + '%)';
        document.getElementById('mem-bar').style.width = memPct + '%';
        document.getElementById('disk-usage').textContent = d.system.disk_recordings;

        // Services
        const ldmEl = document.getElementById('lightdm-status');
        ldmEl.className = d.services.lightdm === 'running' ? 'badge badge-green' : 'badge badge-red';
        ldmEl.textContent = d.services.lightdm === 'running' ? '● Running' : '● Stopped';

        const vncEl = document.getElementById('vnc-status');
        vncEl.className = d.services.vnc === 'running' ? 'badge badge-green' : 'badge badge-red';
        vncEl.textContent = d.services.vnc === 'running' ? '● Running' : '● Stopped';
        document.getElementById('novnc-link').href = d.services.novnc_url;
        
        const hostIp = d.services.novnc_url ? d.services.novnc_url.split(':')[1].replace('//', '') : 'localhost';
        document.getElementById('restreamer-link').href = 'http://' + hostIp + ':8080';

        // Timestamp
        document.getElementById('last-update').textContent =
          new Date(d.timestamp).toLocaleString();
      } catch (e) {
        console.error('Status fetch failed:', e);
      }
    }

    fetchStatus();
    setInterval(fetchStatus, 10000);
  </script>
</body>
</html>
HTMLEOF

# Nginx configuration for dashboard (listening on port 8888)
cat <<EOF >/etc/nginx/sites-available/obs-dashboard
server {
    listen ${OBS_DASHBOARD_PORT};
    server_name _;

    root /var/www/obs-dashboard;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # SvelteKit _app assets for obs-web
    location /_app/ {
        alias /var/www/obs-dashboard/obs-web/_app/;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    location /obs-web/ {
        alias /var/www/obs-dashboard/obs-web/;
        try_files \$uri \$uri/ /obs-web/index.html;
    }

    location /api/ {
        add_header Cache-Control "no-cache, no-store, must-revalidate";
        add_header Access-Control-Allow-Origin "*";
    }

    location /ws {
        proxy_pass http://127.0.0.1:${OBS_WEBSOCKET_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
    }
}
EOF

ln -sf /etc/nginx/sites-available/obs-dashboard /etc/nginx/sites-enabled/obs-dashboard
rm -f /etc/nginx/sites-enabled/default

# Generate initial status
/usr/local/bin/obs-status-update.sh

# Cron job for status updates (every 30 seconds)
cat <<'EOF' >/etc/cron.d/obs-status
* * * * * root /usr/local/bin/obs-status-update.sh >/dev/null 2>&1
* * * * * root sleep 30 && /usr/local/bin/obs-status-update.sh >/dev/null 2>&1
EOF

msg_ok "Set up OBS Web Dashboard & Control Panel"

# ==============================================================================
# RESTREAMER INTEGRATION INSTALLATION (IF REQUESTED)
# ==============================================================================
if [[ -f /etc/restreamer.env ]]; then
  msg_info "Installing Datarhei Restreamer Integration"
  $STD apt-get install -y ca-certificates curl gnupg lsb-release
  mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs 2>/dev/null || echo "noble") stable" > /etc/apt/sources.list.d/docker.list

  $STD apt-get update
  $STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
  curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list

  $STD apt-get update
  $STD apt-get install -y nvidia-container-toolkit 2>/dev/null || true
  nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
  systemctl restart docker >/dev/null 2>&1 || true

  cat <<'EOF' >/usr/local/bin/start-restreamer.sh
#!/usr/bin/env bash
export HOME=/root

if [[ -f /etc/restreamer.env ]]; then
  source /etc/restreamer.env
fi

RS_USERNAME="${RS_USERNAME:-admin}"
RS_PASSWORD="${RS_PASSWORD:-admin123}"

DOCKER_IMAGE="datarhei/restreamer:latest"
GPU_FLAGS=()

if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  DOCKER_IMAGE="datarhei/restreamer:cuda-latest"
  GPU_FLAGS+=("--gpus" "all")
elif [[ -e /dev/dri/renderD128 ]]; then
  DOCKER_IMAGE="datarhei/restreamer:vaapi-latest"
  GPU_FLAGS+=("--device" "/dev/dri:/dev/dri")
fi

mkdir -p /opt/restreamer/config /opt/restreamer/data
docker stop restreamer >/dev/null 2>&1 || true
docker rm restreamer >/dev/null 2>&1 || true
docker pull "${DOCKER_IMAGE}" || true

exec docker run --rm --name restreamer \
  "${GPU_FLAGS[@]}" \
  --privileged \
  -e "RS_USERNAME=${RS_USERNAME}" \
  -e "RS_PASSWORD=${RS_PASSWORD}" \
  -v /opt/restreamer/config:/core/config \
  -v /opt/restreamer/data:/core/data \
  -p 8080:8080 \
  -p 8181:8181 \
  -p 1935:1935 \
  -p 1936:1936 \
  -p 6000:6000/udp \
  "${DOCKER_IMAGE}"
EOF
  chmod +x /usr/local/bin/start-restreamer.sh

  cat <<EOF >/etc/systemd/system/restreamer.service
[Unit]
Description=Datarhei Restreamer Container
After=docker.service network-online.target
Wants=docker.service network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/start-restreamer.sh
ExecStop=/usr/bin/docker stop restreamer
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl enable -q --now restreamer.service
  msg_ok "Installed Datarhei Restreamer Integration"
fi

# ==============================================================================
# SYSTEMD SERVICES
# ==============================================================================
msg_info "Creating Services"

# Main OBS web desktop service
cat <<EOF >/etc/systemd/system/obs-web.service
[Unit]
Description=OBS Studio Headless Web Desktop & Auto-Stream
After=network.target lightdm.service

[Service]
Type=simple
Environment=DISPLAY=${OBS_DISPLAY}
Environment=HOME=/root
Environment=PULSE_SERVER=unix:/tmp/pulseaudio.socket
ExecStart=/usr/local/bin/start-obs-web.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now obs-web.service
systemctl enable -q --now nginx
systemctl restart nginx || true
msg_ok "Created Services"

motd_ssh
customize
cleanup_lxc
