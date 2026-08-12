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
OBS_NOVNC_PORT="${OBS_NOVNC_PORT:-8081}"
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

msg_info "Installing NVIDIA CUDA 12 Toolkit & Repository"
KEYRING_TMP="$(mktemp)"
if curl -fsSL -o "${KEYRING_TMP}" "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb" 2>/dev/null; then
  $STD dpkg -i "${KEYRING_TMP}" 2>/dev/null || true
fi
rm -f "${KEYRING_TMP}"

$STD apt-get update 2>/dev/null || true
$STD apt-get install -y --no-install-recommends cuda-toolkit-12-0 nvidia-cuda-toolkit 2>/dev/null || \
$STD apt-get install -y --no-install-recommends nvidia-cuda-toolkit 2>/dev/null || true

cat <<'CUDAENV' >/etc/profile.d/cuda.sh
export PATH=/usr/local/cuda-12/bin:/usr/local/cuda/bin:${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda-12/lib64:/usr/local/cuda/lib64:${LD_LIBRARY_PATH}
CUDAENV
chmod +x /etc/profile.d/cuda.sh
msg_ok "Installed NVIDIA CUDA 12 Toolkit"

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

if (command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null) || ls /dev/nvidia* &>/dev/null || (command -v lspci &>/dev/null && lspci 2>/dev/null | grep -qi "nvidia"); then
  GPU_ENCODER="nvenc"
  GPU_INFO="NVENC (NVIDIA GPU)"
elif [[ -e /dev/dri/renderD128 ]]; then
  if command -v vainfo &>/dev/null && vainfo 2>/dev/null | grep -qi "vaapi"; then
    GPU_ENCODER="vaapi"
    GPU_INFO="VAAPI (Intel/AMD GPU)"
  elif ls /dev/dri/renderD* &>/dev/null; then
    GPU_ENCODER="vaapi"
    GPU_INFO="VAAPI (GPU detected)"
  fi
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
mkdir -p /opt/obs-studio/scripts /opt/obs-studio/dashboard /opt/obs-studio/recordings
cat <<EOF >/opt/obs-studio/scripts/start-obs-web.sh
#!/usr/bin/env bash
export DISPLAY=${OBS_DISPLAY}
export HOME=/root
export XDG_RUNTIME_DIR=/tmp/runtime-root
export QT_QPA_PLATFORM=xcb
export PULSE_SERVER=unix:/tmp/pulseaudio.socket

mkdir -p /tmp/runtime-root /tmp/.X11-unix /opt/obs-studio/recordings
chmod 700 /tmp/runtime-root
chmod 1777 /tmp/.X11-unix

DISP_NUM="${OBS_DISPLAY#:}"
rm -f "/tmp/.X\${DISP_NUM}-lock" "/tmp/.X11-unix/X\${DISP_NUM}"

# Ensure D-Bus session bus is running for Qt/OBS
if [ -z "\${DBUS_SESSION_BUS_ADDRESS}" ]; then
  eval \$(dbus-launch --sh-syntax --exit-with-session 2>/dev/null || true)
fi

# Start virtual framebuffer if LightDM/Xorg/Xvfb isn't active on display
if ! pgrep -f "Xvfb ${OBS_DISPLAY}" >/dev/null && ! pgrep -f "Xorg ${OBS_DISPLAY}" >/dev/null; then
  Xvfb ${OBS_DISPLAY} -screen 0 ${OBS_RESOLUTION}x24 -ac +render -noreset &
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
  x11vnc -display ${OBS_DISPLAY} -forever -shared -nopw -rfbport ${OBS_VNC_PORT} -noxrecord -noxfixes -noxdamage -bg -o /var/log/x11vnc.log 2>/dev/null || true
  sleep 1
fi

# Start websockify / noVNC on port 8081
if ! pgrep -f "websockify" >/dev/null; then
  websockify --web /usr/share/novnc ${OBS_NOVNC_PORT} 127.0.0.1:${OBS_VNC_PORT} &
  sleep 1
fi

# Launch OBS Studio in persistent monitor loop
while true; do
  if ! pgrep -f "Xvfb ${OBS_DISPLAY}" >/dev/null && ! pgrep -f "Xorg ${OBS_DISPLAY}" >/dev/null; then
    rm -f "/tmp/.X\${DISP_NUM}-lock" "/tmp/.X11-unix/X\${DISP_NUM}"
    Xvfb ${OBS_DISPLAY} -screen 0 ${OBS_RESOLUTION}x24 -ac +render -noreset &
    sleep 2
  fi

  if ! pgrep -f "bin/obs" >/dev/null && ! pgrep -x obs >/dev/null; then
    obs --profile "Headless" --collection "Headless" --startstreaming >>/var/log/obs-studio.log 2>&1 || \
    obs --profile "Headless" --collection "Headless" >>/var/log/obs-studio.log 2>&1 || \
    obs >>/var/log/obs-studio.log 2>&1
  fi
  sleep 3
done
EOF
chmod +x /opt/obs-studio/scripts/start-obs-web.sh
ln -sf /opt/obs-studio/scripts/start-obs-web.sh /usr/local/bin/start-obs-web.sh

msg_ok "Configured VNC & noVNC Web Desktop"

# ==============================================================================
# STATUS DASHBOARD & OBS-WEB CONTROL PANEL (PORT 8888)
# ==============================================================================
msg_info "Setting up OBS Web Dashboard & Control Panel"

mkdir -p /opt/obs-studio/dashboard /opt/obs-studio/dashboard/api
rm -rf /opt/obs-studio/dashboard/obs-web

# Fetch Niek's pre-built OBS-Web frontend (gh-pages)
if command -v git >/dev/null 2>&1; then
git clone --depth 1 -b gh-pages https://github.com/Niek/obs-web.git /opt/obs-studio/dashboard/obs-web 2>/dev/null || true
fi

if [[ ! -f /opt/obs-studio/dashboard/obs-web/index.html ]]; then
  mkdir -p /opt/obs-studio/dashboard/obs-web
  curl -fsSL https://codeload.github.com/Niek/obs-web/tar.gz/refs/heads/gh-pages | tar -xz -C /opt/obs-studio/dashboard/obs-web --strip-components=1 2>/dev/null || true
fi

# Control API Daemon script (Python 3 standard library backend on port 8889)
cat <<'APIEEOF' >/opt/obs-studio/scripts/obs-dashboard-api.py
#!/usr/bin/env python3
import http.server
import json
import os
import socket
import struct
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request

PORT = 8889
DEFAULT_CLIENT_ID = "871542478310-4n88v8h1v5n1b4.apps.googleusercontent.com"
GOOGLE_DEVICE_CODE_URL = "https://oauth2.googleapis.com/device/code"
GOOGLE_TOKEN_URL = "https://oauth2.googleapis.com/token"
YOUTUBE_STREAMS_URL = "https://www.googleapis.com/youtube/v3/liveStreams?part=cdn,status&mine=true"
YOUTUBE_CHANNELS_URL = "https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true"
OAUTH_FILE = "/opt/obs-studio/google_oauth.json"

def http_post_form(url, data_dict):
    encoded_data = urllib.parse.urlencode(data_dict).encode('utf-8')
    req = urllib.request.Request(url, data=encoded_data, headers={'Content-Type': 'application/x-www-form-urlencoded'})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode('utf-8'))

def http_get_json(url, access_token):
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {access_token}'})
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read().decode('utf-8'))

def send_obs_ws_query(request_type, request_data=None):
    """Sends a WebSocket 5.x request and returns (success, response_dict)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(3.0)
        s.connect(('127.0.0.1', 4455))
        
        ws_key = "dGhlIHNhbXBsZSBub25jZQ=="
        req = (
            "GET / HTTP/1.1\r\n"
            "Host: 127.0.0.1:4455\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {ws_key}\r\n"
            "Sec-WebSocket-Version: 13\r\n\r\n"
        )
        s.sendall(req.encode('utf-8'))
        resp = s.recv(1024)
        if b"101 Switching Protocols" not in resp:
            s.close()
            return False, {}

        s.recv(4096)  # Op 0 Hello

        def make_frame(data):
            length = len(data)
            header = bytearray([0x81])
            if length < 126:
                header.append(0x80 | length)
            elif length < 65536:
                header.append(0x80 | 126)
                header.extend(struct.pack('!H', length))
            mask = b'\x00\x00\x00\x00'
            header.extend(mask)
            masked = bytearray(b ^ mask[i % 4] for i, b in enumerate(data))
            return bytes(header + masked)

        id_payload = json.dumps({"op": 1, "d": {"rpcVersion": 1}}).encode('utf-8')
        s.sendall(make_frame(id_payload))
        s.recv(4096)  # Op 2 Identified

        req_obj = {
            "op": 6,
            "d": {
                "requestType": request_type,
                "requestId": "dash-cmd"
            }
        }
        if request_data:
            req_obj["d"]["requestData"] = request_data

        s.sendall(make_frame(req_obj))
        resp_buf = s.recv(8192)
        s.close()

        json_start = resp_buf.find(b'{')
        if json_start != -1:
            resp_data = json.loads(resp_buf[json_start:].decode('utf-8', errors='ignore'))
            if resp_data.get("op") == 7:
                return True, resp_data.get("d", {}).get("responseData", {})
        return True, {}
    except Exception:
        return False, {}

def get_stream_config():
    ok, res = send_obs_ws_query("GetStreamServiceSettings")
    if ok and "streamServiceSettings" in res:
        st = res["streamServiceSettings"]
        return {
            "server": st.get("server", ""),
            "key": st.get("key", ""),
            "service_type": res.get("streamServiceType", "rtmp_custom")
        }
    service_json_path = '/root/.config/obs-studio/basic/profiles/Headless/service.json'
    if os.path.exists(service_json_path):
        try:
            with open(service_json_path, 'r') as f:
                d = json.load(f)
                st = d.get("settings", {})
                return {
                    "server": st.get("server", ""),
                    "key": st.get("key", ""),
                    "service_type": d.get("type", "rtmp_custom")
                }
        except Exception:
            pass
    return {"server": "rtmp://127.0.0.1:1935/live", "key": "stream", "service_type": "rtmp_custom"}

def save_stream_config(server_url, stream_key):
    service_json_path = '/root/.config/obs-studio/basic/profiles/Headless/service.json'
    data = {
        "settings": {
            "bwtest": False,
            "key": stream_key,
            "server": server_url,
            "service": "Custom..."
        },
        "type": "rtmp_custom"
    }
    try:
        os.makedirs(os.path.dirname(service_json_path), exist_ok=True)
        with open(service_json_path, 'w') as f:
            json.dump(data, f, indent=4)
    except Exception:
        pass

    send_obs_ws_query("SetStreamServiceSettings", {
        "streamServiceType": "rtmp_custom",
        "streamServiceSettings": {
            "server": server_url,
            "key": stream_key
        }
    })
    return True

class DashboardAPIHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def _send_json(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data).encode('utf-8'))

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/logs':
            query = urllib.parse.parse_qs(parsed.query)
            log_type = query.get('type', ['obs'])[0]
            log_file = '/var/log/obs-studio.log'
            if log_type == 'vnc': log_file = '/var/log/x11vnc.log'
            elif log_type == 'nginx': log_file = '/var/log/nginx/error.log'
            elif log_type == 'api': log_file = '/var/log/obs-dashboard-api.log'
            lines = []
            if os.path.exists(log_file):
                try:
                    with open(log_file, 'r', errors='ignore') as f: lines = f.readlines()[-80:]
                except Exception as e: lines = [f"Error reading log: {str(e)}"]
            else: lines = [f"Log file not found: {log_file}"]
            self._send_json({"success": True, "type": log_type, "logs": "".join(lines)})

        elif parsed.path == '/api/stream-config':
            cfg = get_stream_config()
            self._send_json({"success": True, "config": cfg})

        elif parsed.path == '/api/youtube/status':
            client_id = ""
            if os.path.exists('/opt/obs-studio/google_client_id.txt'):
                try:
                    with open('/opt/obs-studio/google_client_id.txt', 'r') as f:
                        client_id = f.read().strip()
                except Exception: pass

            if os.path.exists(OAUTH_FILE):
                try:
                    with open(OAUTH_FILE, 'r') as f:
                        session = json.load(f)
                    self._send_json({
                        "connected": True,
                        "client_id": client_id or session.get("client_id", ""),
                        "channel_name": session.get("channel_name", "YouTube Channel"),
                        "ingest_url": session.get("ingest_url", "rtmp://a.rtmp.youtube.com/live2"),
                        "updated_at": session.get("updated_at", 0)
                    })
                    return
                except Exception:
                    pass
            self._send_json({"connected": False, "client_id": client_id})

        else:
            self._send_json({"error": "Endpoint not found"}, 404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path == '/api/youtube/oauth-init':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else '{}'
            try: data = json.loads(body)
            except Exception: data = {}
            client_id = data.get('client_id', '').strip()
            if not client_id and os.path.exists('/opt/obs-studio/google_client_id.txt'):
                try:
                    with open('/opt/obs-studio/google_client_id.txt', 'r') as f:
                        client_id = f.read().strip()
                except Exception: pass

            if not client_id:
                self._send_json({"success": False, "message": "Please enter your Google OAuth Client ID from Google Cloud Console first."}, 400)
                return

            try:
                with open('/opt/obs-studio/google_client_id.txt', 'w') as f:
                    f.write(client_id)
            except Exception: pass
            
            try:
                payload = {
                    "client_id": client_id,
                    "scope": "https://www.googleapis.com/auth/youtube.readonly https://www.googleapis.com/auth/youtube.force-ssl"
                }
                res = http_post_form(GOOGLE_DEVICE_CODE_URL, payload)
                self._send_json({
                    "success": True,
                    "device_code": res.get("device_code"),
                    "user_code": res.get("user_code"),
                    "verification_url": res.get("verification_url", "https://www.google.com/device"),
                    "expires_in": res.get("expires_in", 1800),
                    "interval": res.get("interval", 5)
                })
            except urllib.error.HTTPError as err:
                err_body = err.read().decode('utf-8')
                self._send_json({"success": False, "message": f"Google OAuth rejected Client ID ({err.code}): Check that your Client ID is created in Google Cloud Console with Application Type 'TVs and Limited Input devices' or 'Desktop App'."}, 400)
            except Exception as e:
                self._send_json({"success": False, "message": f"Failed to initiate Google OAuth: {str(e)}"}, 500)

        elif parsed.path == '/api/youtube/oauth-poll':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else '{}'
            try: data = json.loads(body)
            except Exception: data = {}
            device_code = data.get('device_code', '').strip()
            client_id = data.get('client_id', '').strip() or DEFAULT_CLIENT_ID
            client_secret = data.get('client_secret', '').strip()

            if not device_code:
                self._send_json({"success": False, "message": "device_code is required"}, 400)
                return

            payload = {
                "client_id": client_id,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": device_code
            }
            if client_secret:
                payload["client_secret"] = client_secret

            try:
                res = http_post_form(GOOGLE_TOKEN_URL, payload)
                if "access_token" in res:
                    access_token = res["access_token"]
                    refresh_token = res.get("refresh_token", "")

                    channel_name = "YouTube Channel"
                    try:
                        ch_data = http_get_json(YOUTUBE_CHANNELS_URL, access_token)
                        if "items" in ch_data and len(ch_data["items"]) > 0:
                            channel_name = ch_data["items"][0]["snippet"]["title"]
                    except Exception: pass

                    stream_key = ""
                    ingest_url = "rtmp://a.rtmp.youtube.com/live2"
                    try:
                        st_data = http_get_json(YOUTUBE_STREAMS_URL, access_token)
                        if "items" in st_data and len(st_data["items"]) > 0:
                            cdn = st_data["items"][0].get("cdn", {})
                            ingest_info = cdn.get("ingestInfo", {})
                            ingest_url = ingest_info.get("ingestAddress", ingest_url)
                            stream_key = ingest_info.get("streamName", "")
                    except Exception as e:
                        self._send_json({"success": False, "message": f"Authorized Google, but error reading YouTube Live Stream: {str(e)}"}, 500)
                        return

                    if not stream_key:
                        self._send_json({"success": False, "message": "Google Account linked, but no active YouTube Live Stream found. Create a stream in YouTube Studio once."}, 400)
                        return

                    session_data = {
                        "client_id": client_id,
                        "client_secret": client_secret,
                        "access_token": access_token,
                        "refresh_token": refresh_token,
                        "channel_name": channel_name,
                        "stream_key": stream_key,
                        "ingest_url": ingest_url,
                        "updated_at": time.time()
                    }
                    with open(OAUTH_FILE, 'w') as f:
                        json.dump(session_data, f, indent=2)

                    save_stream_config(ingest_url, stream_key)
                    self._send_json({
                        "success": True,
                        "status": "authorized",
                        "channel_name": channel_name,
                        "ingest_url": ingest_url,
                        "message": f"Successfully linked YouTube Account ({channel_name})! Stream key applied to OBS."
                    })
                else:
                    self._send_json({"success": False, "status": "pending"})
            except urllib.error.HTTPError as err:
                err_body = err.read().decode('utf-8')
                if "authorization_pending" in err_body:
                    self._send_json({"success": False, "status": "pending"})
                elif "slow_down" in err_body:
                    self._send_json({"success": False, "status": "slow_down"})
                elif "expired_token" in err_body:
                    self._send_json({"success": False, "status": "expired", "message": "Google Authorization code expired. Please try again."})
                else:
                    self._send_json({"success": False, "status": "error", "message": f"OAuth Error: {err_body}"}, 400)
            except Exception as e:
                self._send_json({"success": False, "status": "error", "message": str(e)}, 500)

        elif parsed.path == '/api/youtube/oauth-unlink':
            if os.path.exists(OAUTH_FILE):
                os.remove(OAUTH_FILE)
            self._send_json({"success": True, "message": "YouTube account unlinked."})

        elif parsed.path == '/api/stream-config':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else '{}'
            try: data = json.loads(body)
            except Exception: data = {}
            server_url = data.get('server', '').strip()
            stream_key = data.get('key', '').strip()
            if not server_url:
                self._send_json({"success": False, "message": "Server URL cannot be empty."}, 400)
                return
            save_stream_config(server_url, stream_key)
            self._send_json({"success": True, "message": "Stream server configuration updated & applied to OBS!"})

        elif parsed.path == '/api/action':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8') if content_length > 0 else '{}'
            try: data = json.loads(body)
            except Exception: data = {}
            action = data.get('action', '')
            msg = ""
            success = True

            if action == 'restart-obs':
                subprocess.run("pkill -9 -f 'bin/obs' || pkill -9 obs || true", shell=True)
                msg = "OBS Studio process killed. Auto-restart watchdog is launching a fresh instance."
            elif action == 'start-stream':
                ok, _ = send_obs_ws_query("StartStream")
                msg = "Stream start request sent." if ok else "Failed to send StartStream request."
                success = ok
            elif action == 'stop-stream':
                ok, _ = send_obs_ws_query("StopStream")
                msg = "Stream stop request sent." if ok else "Failed to send StopStream request."
                success = ok
            elif action == 'start-record':
                ok, _ = send_obs_ws_query("StartRecord")
                msg = "Record start request sent." if ok else "Failed to send StartRecord request."
                success = ok
            elif action == 'stop-record':
                ok, _ = send_obs_ws_query("StopRecord")
                msg = "Record stop request sent." if ok else "Failed to send StopRecord request."
                success = ok
            elif action == 'restart-vnc':
                subprocess.run("pkill -9 x11vnc || true", shell=True)
                msg = "X11VNC server killed. Auto-restart watchdog is restarting VNC."
            elif action == 'restart-all':
                subprocess.run("systemctl restart obs-web.service nginx 2>/dev/null || true", shell=True)
                if os.path.exists('/etc/systemd/system/restreamer.service'):
                    subprocess.run("systemctl restart restreamer.service 2>/dev/null || true", shell=True)
                msg = "All background services restarted."
            elif action == 'clean-recordings':
                rec_dir = '/opt/obs-studio/recordings'
                if os.path.exists(rec_dir):
                    subprocess.run(f"rm -rf {rec_dir}/*", shell=True)
                    msg = "Recordings directory cleared successfully."
                else: msg = "Recordings directory not found."
            elif action == 'reload-nginx':
                subprocess.run("systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null", shell=True)
                msg = "Nginx web server reloaded."
            else:
                success = False
                msg = f"Unknown action: {action}"

            subprocess.run("/usr/local/bin/obs-status-update.sh 2>/dev/null || true", shell=True)
            self._send_json({"success": success, "message": msg, "action": action})
        else:
            self._send_json({"error": "Endpoint not found"}, 404)

if __name__ == '__main__':
    server = http.server.HTTPServer(('127.0.0.1', PORT), DashboardAPIHandler)
    server.serve_forever()
APIEEOF
chmod +x /opt/obs-studio/scripts/obs-dashboard-api.py

# Combined Dashboard HTML (Unified OBS Control Panel with Integrated OBS-Web, Stream Setup & Google OAuth YouTube Linking)
cat <<'HTMLEOF' >/opt/obs-studio/dashboard/index.html
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>OBS Studio — Headless Control Panel</title>
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
      padding: 20px;
    }
    .header {
      text-align: center;
      margin-bottom: 20px;
      padding: 20px;
      background: var(--bg-card);
      border: 1px solid var(--border);
      border-radius: 12px;
    }
    .header h1 {
      font-size: 26px;
      font-weight: 600;
      background: var(--gradient-primary);
      -webkit-background-clip: text;
      -webkit-text-fill-color: transparent;
      background-clip: text;
      margin-bottom: 6px;
    }
    .header p { color: var(--text-secondary); font-size: 13px; }
    
    .nav-bar {
      display: flex;
      gap: 10px;
      justify-content: center;
      margin-bottom: 20px;
      flex-wrap: wrap;
    }
    .nav-tab {
      padding: 10px 20px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: var(--bg-card);
      color: var(--text-secondary);
      font-size: 14px;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.2s ease;
    }
    .nav-tab:hover { border-color: var(--accent-blue); color: var(--text-primary); }
    .nav-tab.active {
      background: rgba(88, 166, 255, 0.15);
      border-color: var(--accent-blue);
      color: var(--accent-blue);
    }
    
    .tab-view { display: none; }
    .tab-view.active { display: block; }

    .grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
      gap: 16px;
      max-width: 1280px;
      margin: 0 auto;
    }
    .card {
      background: var(--bg-card);
      border: 1px solid var(--border);
      border-radius: 12px;
      padding: 20px;
    }
    .card-full { grid-column: 1 / -1; }
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
    .badge-green { background: rgba(63, 185, 80, 0.15); color: var(--accent-green); border: 1px solid rgba(63, 185, 80, 0.3); }
    .badge-red { background: rgba(248, 81, 73, 0.15); color: var(--accent-red); border: 1px solid rgba(248, 81, 73, 0.3); }
    .badge-blue { background: rgba(88, 166, 255, 0.15); color: var(--accent-blue); border: 1px solid rgba(88, 166, 255, 0.3); }
    .badge::before { content: ''; width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
    .badge-green::before { background: var(--accent-green); }
    .badge-red::before { background: var(--accent-red); }
    .badge-blue::before { background: var(--accent-blue); }
    .progress-bar { width: 100%; height: 6px; background: var(--border); border-radius: 3px; margin-top: 4px; }
    .progress-fill { height: 100%; border-radius: 3px; background: var(--gradient-primary); transition: width 0.5s ease; }
    .btn-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
      gap: 10px;
      margin-top: 10px;
    }
    .btn {
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 8px;
      padding: 10px 14px;
      border-radius: 8px;
      border: 1px solid var(--border);
      background: var(--bg-primary);
      color: var(--text-primary);
      font-size: 13px;
      font-weight: 600;
      cursor: pointer;
      transition: all 0.2s ease;
      text-decoration: none;
    }
    .btn:hover { border-color: var(--accent-blue); background: rgba(88, 166, 255, 0.12); transform: translateY(-1px); }
    .btn:active { transform: translateY(0); }
    .btn-danger { border-color: rgba(248, 81, 73, 0.5); }
    .btn-danger:hover { background: rgba(248, 81, 73, 0.2); border-color: var(--accent-red); }
    .btn-warning { border-color: rgba(210, 153, 34, 0.5); }
    .btn-warning:hover { background: rgba(210, 153, 34, 0.2); border-color: var(--accent-orange); }
    .btn-success { border-color: rgba(63, 185, 80, 0.5); }
    .btn-success:hover { background: rgba(63, 185, 80, 0.2); border-color: var(--accent-green); }
    .btn-purple { border-color: rgba(188, 140, 255, 0.5); }
    .btn-purple:hover { background: rgba(188, 140, 255, 0.2); border-color: var(--accent-purple); }

    .oauth-box {
      background: #090d13;
      border: 1px solid var(--accent-blue);
      border-radius: 8px;
      padding: 16px;
      margin-top: 16px;
      text-align: center;
    }
    .user-code-display {
      font-size: 24px;
      font-weight: 700;
      letter-spacing: 2px;
      color: var(--accent-green);
      background: var(--bg-card);
      border: 1px dashed var(--accent-green);
      padding: 10px 16px;
      border-radius: 8px;
      margin: 12px 0;
      display: inline-block;
    }

    .form-group { margin-bottom: 16px; }
    .form-label { display: block; font-size: 13px; font-weight: 600; color: var(--text-secondary); margin-bottom: 6px; }
    .form-input, .form-select {
      width: 100%;
      padding: 10px 14px;
      background: #090d13;
      border: 1px solid var(--border);
      border-radius: 8px;
      color: var(--text-primary);
      font-size: 14px;
      font-family: inherit;
    }
    .form-input:focus, .form-select:focus { outline: none; border-color: var(--accent-blue); }

    .tabs { display: flex; gap: 8px; margin-bottom: 12px; border-bottom: 1px solid var(--border); padding-bottom: 8px; }
    .tab-btn { padding: 6px 12px; font-size: 13px; border-radius: 6px; background: transparent; border: 1px solid transparent; color: var(--text-secondary); cursor: pointer; }
    .tab-btn.active { background: rgba(88, 166, 255, 0.15); color: var(--accent-blue); border-color: var(--accent-blue); font-weight: 600; }
    .log-container {
      background: #090d13;
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 12px;
      font-family: 'SFMono-Regular', Consolas, 'Liberation Mono', Menlo, monospace;
      font-size: 12px;
      line-height: 1.5;
      color: #7ee787;
      height: 320px;
      overflow-y: auto;
      white-space: pre-wrap;
      word-break: break-all;
    }

    #toast-container { position: fixed; top: 20px; right: 20px; z-index: 9999; display: flex; flex-direction: column; gap: 10px; }
    .toast { padding: 12px 18px; border-radius: 8px; background: var(--bg-card); border: 1px solid var(--border); color: var(--text-primary); font-size: 13px; box-shadow: 0 8px 24px rgba(0,0,0,0.5); animation: slideIn 0.3s ease; }
    .toast-success { border-color: var(--accent-green); color: var(--accent-green); }
    .toast-error { border-color: var(--accent-red); color: var(--accent-red); }
    .toast-info { border-color: var(--accent-blue); color: var(--accent-blue); }
    @keyframes slideIn { from { transform: translateX(100%); opacity: 0; } to { transform: translateX(0); opacity: 1; } }
    
    .refresh-info { text-align: center; margin-top: 24px; color: var(--text-secondary); font-size: 12px; }
    @keyframes pulse { 0%, 100% { opacity: 1; } 50% { opacity: 0.5; } }
    .loading { animation: pulse 1.5s infinite; }
  </style>
</head>
<body>
  <div id="toast-container"></div>

  <div class="header">
    <h1>🎬 OBS Studio — Headless Control Panel</h1>
    <p>Unified Proxmox LXC Container Management & Live Remote Control</p>
  </div>

  <div class="nav-bar">
    <button id="nav-dash" class="nav-tab active" onclick="switchNav('dash')">📊 Dashboard & Controls</button>
    <button id="nav-obsweb" class="nav-tab" onclick="switchNav('obsweb')">🎛️ OBS Web Remote Control</button>
    <button id="nav-stream" class="nav-tab" onclick="switchNav('stream')">⚙️ Stream Server Setup</button>
    <button id="nav-logs" class="nav-tab" onclick="switchNav('logs')">📋 System Logs</button>
  </div>

  <!-- VIEW 1: DASHBOARD -->
  <div id="view-dash" class="tab-view active">
    <div class="grid">
      <div class="card">
        <div class="card-title"><span class="icon">📡</span> OBS Studio</div>
        <div class="status-row"><span class="status-label">Status</span><span id="obs-status" class="badge badge-red loading">Loading...</span></div>
        <div class="status-row"><span class="status-label">PID</span><span id="obs-pid" class="status-value">—</span></div>
        <div class="status-row"><span class="status-label">Uptime</span><span id="obs-uptime" class="status-value">—</span></div>
        <div class="status-row"><span class="status-label">WebSocket Port</span><span id="obs-ws-port" class="status-value">4455</span></div>
      </div>

      <div class="card">
        <div class="card-title"><span class="icon">🎮</span> GPU & Encoder</div>
        <div class="status-row"><span class="status-label">GPU</span><span id="gpu-info" class="status-value">—</span></div>
        <div class="status-row"><span class="status-label">Encoder</span><span id="gpu-encoder" class="badge badge-blue">—</span></div>
      </div>

      <div class="card">
        <div class="card-title"><span class="icon">⚙️</span> System Resources</div>
        <div class="status-row"><span class="status-label">CPU Usage</span><span id="cpu-usage" class="status-value">—</span></div>
        <div class="status-row" style="flex-direction: column; align-items: stretch;">
          <div style="display: flex; justify-content: space-between;"><span class="status-label">Memory</span><span id="mem-info" class="status-value">—</span></div>
          <div class="progress-bar"><div id="mem-bar" class="progress-fill" style="width: 0%;"></div></div>
        </div>
        <div class="status-row"><span class="status-label">Recordings Disk</span><span id="disk-usage" class="status-value">—</span></div>
      </div>

      <div class="card card-full">
        <div class="card-title"><span class="icon">⚡</span> Quick Control Actions & Management</div>
        <div class="btn-grid">
          <button class="btn btn-warning" onclick="triggerAction('restart-obs', 'Are you sure you want to restart OBS Studio?')">🎬 Restart OBS Studio</button>
          <button class="btn btn-success" onclick="triggerAction('start-stream')">🔴 Start Stream</button>
          <button class="btn btn-danger" onclick="triggerAction('stop-stream')">⏹️ Stop Stream</button>
          <button class="btn btn-purple" onclick="triggerAction('start-record')">⏺️ Start Record</button>
          <button class="btn" onclick="triggerAction('stop-record')">⏹️ Stop Record</button>
          <button class="btn btn-warning" onclick="triggerAction('restart-vnc', 'Restart VNC server?')">🖥️ Restart VNC</button>
          <button class="btn btn-danger" onclick="triggerAction('restart-all', 'Restart all background services?')">🚀 Restart All Services</button>
          <button class="btn btn-warning" onclick="triggerAction('clean-recordings', 'Delete all recordings?')">🧹 Clean Recordings</button>
          <button class="btn" onclick="triggerAction('reload-nginx')">⚡ Reload Nginx</button>
        </div>
      </div>

      <div class="card card-full">
        <div class="card-title"><span class="icon">🔗</span> Integrated Interfaces & Web Tools</div>
        <div class="btn-grid">
          <button onclick="switchNav('obsweb')" class="btn btn-purple">🎛️ Open Integrated OBS Web Control</button>
          <a id="restreamer-link" href="#" target="_blank" class="btn btn-success">📡 Open Restreamer Interface</a>
          <a id="novnc-link" href="#" target="_blank" class="btn">🖥️ Open noVNC Web Desktop</a>
          <a href="/api/status.json" target="_blank" class="btn">📊 System Status JSON API</a>
        </div>
      </div>
    </div>
  </div>

  <!-- VIEW 2: EMBEDDED OBS-WEB REMOTE CONTROL -->
  <div id="view-obsweb" class="tab-view">
    <div class="card card-full" style="padding: 12px;">
      <div class="card-title" style="justify-content: space-between; margin-bottom: 12px;">
        <span>🎛️ OBS Web Remote Control (Integrated Niek Frontend)</span>
        <button class="btn" onclick="reloadObsWebIframe()" style="padding: 4px 10px; font-size: 12px;">🔄 Refresh Controller</button>
      </div>
      <iframe id="obsweb-iframe" src="about:blank" style="width: 100%; height: 720px; border: 1px solid var(--border); border-radius: 8px; background: #000;"></iframe>
    </div>
  </div>

  <!-- VIEW 3: STREAM SERVER SETUP & GOOGLE OAUTH -->
  <div id="view-stream" class="tab-view">
    <div class="grid" style="max-width: 900px;">
      <!-- GOOGLE OAUTH YOUTUBE LINKING -->
      <div class="card card-full">
        <div class="card-title"><span class="icon">🔑</span> Google OAuth YouTube Integration (No Stream Key Required)</div>
        <p style="color: var(--text-secondary); font-size: 13px; margin-bottom: 16px;">
          Link your YouTube Account directly using Google OAuth Device Authorization Flow. OBS Studio will automatically fetch your live stream ingest URL and stream key without needing manual key entry!
        </p>

        <div class="form-group">
          <label class="form-label">Google OAuth Client ID (from Google Cloud Console)</label>
          <input type="text" id="google-client-id" class="form-input" placeholder="e.g. 123456789012-xxxx.apps.googleusercontent.com">
          <small style="color: var(--text-secondary); font-size: 11px; display: block; margin-top: 4px;">
            💡 Create a free OAuth Client ID in <a href="https://console.cloud.google.com/apis/credentials" target="_blank" style="color: var(--accent-blue);">Google Cloud Console</a> (Type: <strong>TVs and Limited Input devices</strong> or <strong>Desktop App</strong>), and enable <strong>YouTube Data API v3</strong>.
          </small>
        </div>

        <div class="status-row">
          <span class="status-label">Google OAuth Status</span>
          <span id="yt-oauth-badge" class="badge badge-red">Not Linked</span>
        </div>
        <div id="yt-channel-row" class="status-row" style="display: none;">
          <span class="status-label">Linked Channel</span>
          <span id="yt-channel-name" class="status-value" style="color: var(--accent-green);">—</span>
        </div>

        <div id="yt-oauth-actions" style="margin-top: 16px;">
          <button id="btn-yt-connect" class="btn btn-danger" onclick="startGoogleOAuth()" style="width: 100%; padding: 12px;">
            🔑 Link YouTube Account via Google OAuth Device Flow
          </button>
          <button id="btn-yt-unlink" class="btn btn-warning" onclick="unlinkGoogleOAuth()" style="width: 100%; padding: 12px; display: none; margin-top: 8px;">
            ❌ Unlink YouTube Account
          </button>
        </div>

        <!-- OAUTH DEVICE FLOW INSTRUCTIONS MODAL/BOX -->
        <div id="oauth-box" class="oauth-box" style="display: none;">
          <h3 style="font-size: 16px; margin-bottom: 8px; color: var(--accent-blue);">Google Authorization Required</h3>
          <p style="font-size: 13px; color: var(--text-secondary);">
            1. Open <a id="oauth-verify-link" href="https://www.google.com/device" target="_blank" style="color: var(--accent-blue); font-weight: 600;">google.com/device</a> in your browser.
          </p>
          <p style="font-size: 13px; color: var(--text-secondary); margin-top: 4px;">
            2. Enter the 8-character code below and click <strong>Allow</strong>:
          </p>
          
          <div id="oauth-user-code" class="user-code-display">LOAD-ING...</div>

          <div style="display: flex; gap: 8px; justify-content: center; margin-bottom: 8px;">
            <button class="btn" onclick="copyOAuthCode()">📋 Copy Code</button>
            <a id="oauth-direct-btn" href="https://www.google.com/device" target="_blank" class="btn btn-success">🔗 Open Google Device Link</a>
          </div>

          <p id="oauth-poll-status" class="loading" style="font-size: 12px; color: var(--accent-orange); margin-top: 8px;">
            ⏳ Waiting for Google authorization...
          </p>
        </div>
      </div>

      <!-- MANUAL / CUSTOM STREAM CONFIG -->
      <div class="card card-full">
        <div class="card-title"><span class="icon">⚙️</span> Manual Stream Server & Ingest Configuration</div>
        <p style="color: var(--text-secondary); font-size: 13px; margin-bottom: 16px;">
          Alternatively, configure custom RTMP/SRT stream destinations manually.
        </p>

        <div class="form-group">
          <label class="form-label">Streaming Service Preset</label>
          <select id="stream-preset" class="form-select" onchange="applyPreset()">
            <option value="custom">⚙️ Custom RTMP / SRT Ingest Server</option>
            <option value="youtube">🔴 YouTube Live (rtmp://a.rtmp.youtube.com/live2)</option>
            <option value="twitch">🟣 Twitch Live (rtmp://live.twitch.tv/app/)</option>
            <option value="facebook">🔵 Facebook Live (rtmps://live-api-s.facebook.com:443/rtmp/)</option>
            <option value="restreamer">📡 Local Restreamer Engine (rtmp://127.0.0.1:1935/live)</option>
          </select>
        </div>

        <div class="form-group">
          <label class="form-label">Server Ingest URL (RTMP / RTMPS / SRT)</label>
          <input type="text" id="stream-server" class="form-input" placeholder="rtmp://a.rtmp.youtube.com/live2">
        </div>

        <div class="form-group">
          <label class="form-label">Stream Key / Passcode</label>
          <div style="display: flex; gap: 8px;">
            <input type="password" id="stream-key" class="form-input" placeholder="Enter stream key...">
            <button class="btn" onclick="toggleKeyVisibility()" style="white-space: nowrap;">👁️ Show/Hide</button>
          </div>
        </div>

        <div style="display: flex; gap: 12px; margin-top: 24px;">
          <button class="btn btn-success" onclick="saveStreamConfig()" style="flex: 1; padding: 12px;">💾 Save & Apply Stream Config</button>
          <button class="btn" onclick="loadStreamConfig()" style="padding: 12px;">🔄 Reload Current Settings</button>
        </div>
      </div>
    </div>
  </div>

  <!-- VIEW 4: SYSTEM LOGS -->
  <div id="view-logs" class="tab-view">
    <div class="grid" style="max-width: 1280px;">
      <div class="card card-full">
        <div class="card-title" style="justify-content: space-between;">
          <span><span class="icon">📋</span> Live System Logs Viewer</span>
          <div style="display: flex; gap: 8px;">
            <button class="btn" onclick="loadLog(activeLogType)" style="padding: 4px 10px; font-size: 12px;">🔄 Refresh Log</button>
            <button class="btn" onclick="copyLog()" style="padding: 4px 10px; font-size: 12px;">📋 Copy Log</button>
          </div>
        </div>
        <div class="tabs">
          <button id="tab-obs" class="tab-btn active" onclick="loadLog('obs')">🎬 OBS Studio Log</button>
          <button id="tab-vnc" class="tab-btn" onclick="loadLog('vnc')">🖥️ VNC Log</button>
          <button id="tab-nginx" class="tab-btn" onclick="loadLog('nginx')">🌐 Nginx Log</button>
          <button id="tab-api" class="tab-btn" onclick="loadLog('api')">⚡ Control API Log</button>
        </div>
        <div id="log-console" class="log-container">Loading logs...</div>
      </div>
    </div>
  </div>

  <div class="refresh-info">
    Auto-refresh every 10 seconds · Last update: <span id="last-update">—</span>
  </div>

  <script>
    let activeLogType = 'obs';
    let oauthPollInterval = null;
    let currentDeviceCode = null;

    function showToast(msg, type = 'info') {
      const container = document.getElementById('toast-container');
      const toast = document.createElement('div');
      toast.className = `toast toast-${type}`;
      toast.textContent = msg;
      container.appendChild(toast);
      setTimeout(() => {
        toast.style.opacity = '0';
        toast.style.transition = 'opacity 0.3s';
        setTimeout(() => toast.remove(), 300);
      }, 4000);
    }

    function switchNav(tab) {
      document.querySelectorAll('.nav-tab').forEach(t => t.classList.remove('active'));
      document.querySelectorAll('.tab-view').forEach(v => v.classList.remove('active'));
      
      const navBtn = document.getElementById('nav-' + tab);
      const viewEl = document.getElementById('view-' + tab);
      if (navBtn) navBtn.classList.add('active');
      if (viewEl) viewEl.classList.add('active');

      if (tab === 'obsweb') {
        const iframe = document.getElementById('obsweb-iframe');
        if (iframe.src === 'about:blank' || !iframe.src) {
          reloadObsWebIframe();
        }
      } else if (tab === 'stream') {
        loadStreamConfig();
        checkGoogleOAuthStatus();
      } else if (tab === 'logs') {
        loadLog(activeLogType);
      }
    }

    function reloadObsWebIframe() {
      const hostIp = window.location.hostname;
      const iframe = document.getElementById('obsweb-iframe');
      iframe.src = '/obs-web/?host=' + hostIp + ':4455';
    }

    async function triggerAction(actionName, confirmMsg) {
      if (confirmMsg && !confirm(confirmMsg)) return;
      showToast(`Executing action: ${actionName}...`, 'info');
      try {
        const res = await fetch('/api/action', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: actionName })
        });
        const data = await res.json();
        if (data.success) {
          showToast(data.message || 'Action executed successfully!', 'success');
          setTimeout(fetchStatus, 1500);
        } else {
          showToast(`Action failed: ${data.message || 'Unknown error'}`, 'error');
        }
      } catch (err) {
        showToast(`Network error: ${err.message}`, 'error');
      }
    }

    /* GOOGLE OAUTH YOUTUBE FLOW */
    async function checkGoogleOAuthStatus() {
      try {
        const res = await fetch('/api/youtube/status?_=' + Date.now());
        const data = await res.json();
        const badge = document.getElementById('yt-oauth-badge');
        const channelRow = document.getElementById('yt-channel-row');
        const channelName = document.getElementById('yt-channel-name');
        const btnConnect = document.getElementById('btn-yt-connect');
        const btnUnlink = document.getElementById('btn-yt-unlink');
        const clientIdInput = document.getElementById('google-client-id');

        if (data.client_id && clientIdInput) {
          clientIdInput.value = data.client_id;
        }

        if (data.connected) {
          badge.className = 'badge badge-green';
          badge.textContent = 'Linked to Google YouTube';
          channelRow.style.display = 'flex';
          channelName.textContent = data.channel_name;
          btnConnect.style.display = 'none';
          btnUnlink.style.display = 'block';
        } else {
          badge.className = 'badge badge-red';
          badge.textContent = 'Not Linked';
          channelRow.style.display = 'none';
          btnConnect.style.display = 'block';
          btnUnlink.style.display = 'none';
        }
      } catch (e) {
        console.error('Failed to check OAuth status:', e);
      }
    }

    async function startGoogleOAuth() {
      const clientId = document.getElementById('google-client-id').value.trim();
      if (!clientId) {
        showToast('Please enter your Google OAuth Client ID first.', 'error');
        return;
      }
      showToast('Initiating Google OAuth Device Flow...', 'info');
      try {
        const res = await fetch('/api/youtube/oauth-init', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ client_id: clientId })
        });
        const data = await res.json();
        if (data.success) {
          currentDeviceCode = data.device_code;
          document.getElementById('oauth-box').style.display = 'block';
          document.getElementById('oauth-user-code').textContent = data.user_code;
          document.getElementById('oauth-verify-link').href = data.verification_url;
          document.getElementById('oauth-direct-btn').href = data.verification_url;
          
          if (oauthPollInterval) clearInterval(oauthPollInterval);
          oauthPollInterval = setInterval(pollGoogleOAuthToken, (data.interval || 5) * 1000);
          showToast('Enter code ' + data.user_code + ' at google.com/device', 'info');
        } else {
          showToast('OAuth init failed: ' + data.message, 'error');
        }
      } catch (err) {
        showToast('Network error: ' + err.message, 'error');
      }
    }

    async function pollGoogleOAuthToken() {
      if (!currentDeviceCode) return;
      try {
        const res = await fetch('/api/youtube/oauth-poll', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ device_code: currentDeviceCode })
        });
        const data = await res.json();
        if (data.success && data.status === 'authorized') {
          clearInterval(oauthPollInterval);
          oauthPollInterval = null;
          document.getElementById('oauth-box').style.display = 'none';
          showToast(data.message || 'YouTube account linked successfully!', 'success');
          checkGoogleOAuthStatus();
          loadStreamConfig();
        } else if (data.status === 'expired') {
          clearInterval(oauthPollInterval);
          oauthPollInterval = null;
          showToast('Authorization code expired. Please restart authorization.', 'error');
          document.getElementById('oauth-box').style.display = 'none';
        }
      } catch (e) {
        console.error('OAuth poll error:', e);
      }
    }

    async function unlinkGoogleOAuth() {
      if (!confirm('Are you sure you want to unlink your Google YouTube account?')) return;
      try {
        const res = await fetch('/api/youtube/oauth-unlink', { method: 'POST' });
        const data = await res.json();
        showToast(data.message || 'Unlinked.', 'info');
        checkGoogleOAuthStatus();
      } catch (e) {
        showToast('Failed to unlink: ' + e.message, 'error');
      }
    }

    function copyOAuthCode() {
      const code = document.getElementById('oauth-user-code').textContent;
      navigator.clipboard.writeText(code).then(() => {
        showToast('Code copied: ' + code, 'success');
      });
    }

    function applyPreset() {
      const preset = document.getElementById('stream-preset').value;
      const serverInput = document.getElementById('stream-server');
      if (preset === 'youtube') serverInput.value = 'rtmp://a.rtmp.youtube.com/live2';
      else if (preset === 'twitch') serverInput.value = 'rtmp://live.twitch.tv/app/';
      else if (preset === 'facebook') serverInput.value = 'rtmps://live-api-s.facebook.com:443/rtmp/';
      else if (preset === 'restreamer') serverInput.value = 'rtmp://127.0.0.1:1935/live';
    }

    function toggleKeyVisibility() {
      const keyInput = document.getElementById('stream-key');
      keyInput.type = keyInput.type === 'password' ? 'text' : 'password';
    }

    async function loadStreamConfig() {
      try {
        const res = await fetch('/api/stream-config?_=' + Date.now());
        const data = await res.json();
        if (data.success && data.config) {
          document.getElementById('stream-server').value = data.config.server || '';
          document.getElementById('stream-key').value = data.config.key || '';
        }
      } catch (err) {
        showToast('Failed to load stream settings: ' + err.message, 'error');
      }
    }

    async function saveStreamConfig() {
      const server = document.getElementById('stream-server').value.trim();
      const key = document.getElementById('stream-key').value.trim();
      if (!server) {
        showToast('Please enter a valid Stream Server URL.', 'error');
        return;
      }
      showToast('Saving stream configuration...', 'info');
      try {
        const res = await fetch('/api/stream-config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ server, key })
        });
        const data = await res.json();
        if (data.success) {
          showToast(data.message || 'Stream config saved & applied!', 'success');
        } else {
          showToast('Failed to save config: ' + data.message, 'error');
        }
      } catch (err) {
        showToast('Network error saving config: ' + err.message, 'error');
      }
    }

    async function loadLog(type) {
      activeLogType = type;
      document.querySelectorAll('.tab-btn').forEach(b => b.classList.remove('active'));
      const activeTab = document.getElementById('tab-' + type);
      if (activeTab) activeTab.classList.add('active');
      
      const consoleEl = document.getElementById('log-console');
      consoleEl.textContent = `Loading ${type} logs...`;
      try {
        const res = await fetch(`/api/logs?type=${type}&_=${Date.now()}`);
        const data = await res.json();
        consoleEl.textContent = data.logs || 'No log content available.';
        consoleEl.scrollTop = consoleEl.scrollHeight;
      } catch (err) {
        consoleEl.textContent = `Failed to fetch logs: ${err.message}`;
      }
    }

    function copyLog() {
      const consoleEl = document.getElementById('log-console');
      navigator.clipboard.writeText(consoleEl.textContent).then(() => {
        showToast('Logs copied to clipboard!', 'success');
      }).catch(() => {
        showToast('Failed to copy logs', 'error');
      });
    }

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

        const hostIp = window.location.hostname;
        document.getElementById('novnc-link').href = 'http://' + hostIp + ':8081/vnc.html?autoconnect=true&resize=remote';
        document.getElementById('restreamer-link').href = 'http://' + hostIp + ':8080/';

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

    root /opt/obs-studio/dashboard;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location = /obs-web {
        return 301 /obs-web/;
    }

    location /obs-web/ {
        root /opt/obs-studio/dashboard;
        index index.html;
        try_files \$uri \$uri/ /obs-web/index.html;
    }

    location /_app/ {
        root /opt/obs-studio/dashboard/obs-web;
        expires 30d;
        add_header Cache-Control "public, no-transform";
    }

    location /favicon.png {
        root /opt/obs-studio/dashboard/obs-web;
    }

    location /manifest.json {
        root /opt/obs-studio/dashboard/obs-web;
    }

    location /api/youtube/ {
        proxy_pass http://127.0.0.1:8889/api/youtube/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location /api/stream-config {
        proxy_pass http://127.0.0.1:8889/api/stream-config;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location /api/action {
        proxy_pass http://127.0.0.1:8889/api/action;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
    }

    location /api/logs {
        proxy_pass http://127.0.0.1:8889/api/logs;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
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

# Create Status Update Script /usr/local/bin/obs-status-update.sh (Python 3)
cat <<'STATUSEOF' >/usr/local/bin/obs-status-update.sh
#!/usr/bin/env python3
import json, os, subprocess, time

os.makedirs('/opt/obs-studio/dashboard/api', exist_ok=True)

obs_status = "stopped"
obs_pid = ""
obs_uptime = ""

try:
    res = subprocess.run(["pgrep", "-f", "bin/obs"], capture_output=True, text=True)
    pids = res.stdout.strip().split()
    if not pids:
        res = subprocess.run(["pgrep", "-x", "obs"], capture_output=True, text=True)
        pids = res.stdout.strip().split()
    if pids:
        obs_status = "running"
        obs_pid = pids[0]
        up_res = subprocess.run(["ps", "-p", obs_pid, "-o", "etime="], capture_output=True, text=True)
        obs_uptime = up_res.stdout.strip() or "active"
except Exception: pass

gpu_name = "Software / CPU"
gpu_enc = "x264 (CPU)"
try:
    smi = subprocess.run(["nvidia-smi", "--query-gpu=gpu_name", "--format=csv,noheader"], capture_output=True, text=True)
    if smi.returncode == 0 and smi.stdout.strip():
        gpu_name = smi.stdout.strip().split('\n')[0]
        gpu_enc = "nvenc (NVIDIA GPU)"
except Exception: pass

cpu_usage = "0"
try:
    top_res = subprocess.run("top -bn1 2>/dev/null | grep 'Cpu(s)' | awk '{print $2 + $4}'", shell=True, capture_output=True, text=True)
    cpu_usage = top_res.stdout.strip() or "0"
except Exception: pass

mem_total, mem_used = 0, 0
try:
    free_res = subprocess.run("free -m 2>/dev/null | awk '/Mem:/ {print $2 \" \" $3}'", shell=True, capture_output=True, text=True)
    parts = free_res.stdout.strip().split()
    if len(parts) >= 2:
        mem_total = int(parts[0])
        mem_used = int(parts[1])
except Exception: pass

rec_disk = "N/A"
try:
    df_res = subprocess.run("df -h /opt/obs-studio/recordings 2>/dev/null | tail -n1 | awk '{print $3 \"/\" $2 \" (\" $5 \")\"}'", shell=True, capture_output=True, text=True)
    rec_disk = df_res.stdout.strip() or "N/A"
except Exception: pass

data = {
    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
    "obs": {
        "status": obs_status,
        "pid": obs_pid,
        "uptime": obs_uptime,
        "websocket_port": 4455
    },
    "gpu": {
        "info": gpu_name,
        "encoder": gpu_enc
    },
    "system": {
        "cpu_usage": cpu_usage,
        "memory_total_mb": mem_total,
        "memory_used_mb": mem_used,
        "disk_recordings": rec_disk
    }
}

try:
    with open('/opt/obs-studio/dashboard/api/status.json', 'w') as f:
        json.dump(data, f, indent=2)
except Exception: pass
STATUSEOF
chmod +x /usr/local/bin/obs-status-update.sh

# Generate initial status
/usr/local/bin/obs-status-update.sh 2>/dev/null || true

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

# Dashboard API Daemon systemd service
cat <<EOF >/etc/systemd/system/obs-dashboard-api.service
[Unit]
Description=OBS Studio Dashboard Control API Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/obs-studio/scripts/obs-dashboard-api.py
Restart=always
RestartSec=3
StandardOutput=append:/var/log/obs-dashboard-api.log
StandardError=append:/var/log/obs-dashboard-api.log

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now obs-dashboard-api.service
systemctl enable -q --now obs-web.service
systemctl enable -q --now nginx
systemctl restart nginx || true

# Create native LXC container update helper script /usr/local/bin/obs-update
cat <<'UPDATEEOF' >/usr/local/bin/obs-update
#!/usr/bin/env bash
set -e
echo "=============================================================================="
echo "  Updating OBS Studio LXC Container, Control Panel & System Packages..."
echo "=============================================================================="

echo "--> Updating APT package lists and OBS Studio..."
apt-get update -qq
apt-get install -y --only-upgrade obs-studio 2>/dev/null || true

echo "--> Updating OBS-Web Remote Control Frontend..."
if [ ! -d /opt/obs-studio/dashboard/obs-web ]; then
  rm -rf /opt/obs-studio/dashboard/obs-web
  git clone --depth 1 -b gh-pages https://github.com/Niek/obs-web.git /opt/obs-studio/dashboard/obs-web 2>/dev/null || (mkdir -p /opt/obs-studio/dashboard/obs-web && curl -fsSL https://codeload.github.com/Niek/obs-web/tar.gz/refs/heads/gh-pages | tar -xz -C /opt/obs-studio/dashboard/obs-web --strip-components=1 2>/dev/null || true)
else
  (cd /opt/obs-studio/dashboard/obs-web && git pull 2>/dev/null) || true
fi

echo "--> Reloading services & status..."
systemctl daemon-reload 2>/dev/null || true
systemctl restart obs-dashboard-api.service obs-web.service nginx 2>/dev/null || true
if [ -x /usr/local/bin/obs-status-update.sh ]; then
  /usr/local/bin/obs-status-update.sh 2>/dev/null || true
fi

echo "=============================================================================="
echo "  ✔️ OBS Studio LXC Container updated successfully!"
echo "=============================================================================="
UPDATEEOF
chmod +x /usr/local/bin/obs-update
ln -sf /usr/local/bin/obs-update /usr/local/bin/update

msg_ok "Created Services & Update Helper"

# Create credentials.txt management file
CONTAINER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "LXC_IP")
cat <<EOF >/opt/obs-studio/credentials.txt
==============================================================================
  OBS Studio Headless LXC — System Credentials & Access Info
==============================================================================

[Access URLs & Ports]
- Status Dashboard & Control Panel: http://${CONTAINER_IP}:8888
- OBS Web Remote Control:           http://${CONTAINER_IP}:8888/obs-web/
- noVNC Interactive Web Desktop:    http://${CONTAINER_IP}:8081/vnc.html?autoconnect=true&resize=remote
- OBS WebSocket Port:               4455 (Auth: Disabled)
- VNC Direct Server Port:           5900

[Restreamer Live Streaming Engine]
- Restreamer Web Interface:        http://${CONTAINER_IP}:8080
- Admin Username:                   admin
- Admin Password:                   admin123
- RTMP Stream Ingest URL:           rtmp://${CONTAINER_IP}:1935/live/stream
- SRT Stream Ingest URL:            srt://${CONTAINER_IP}:6000

[Storage Directories]
- OBS Application Root:             /opt/obs-studio
- OBS Recordings Path:              /opt/obs-studio/recordings
- Dashboard Directory:              /opt/obs-studio/dashboard
- Restreamer Config Path:           /opt/restreamer/config
- Restreamer Data Path:             /opt/restreamer/data
- Credentials File:                 /opt/obs-studio/credentials.txt
==============================================================================
EOF
chmod 644 /opt/obs-studio/credentials.txt

motd_ssh
customize
cleanup_lxc
