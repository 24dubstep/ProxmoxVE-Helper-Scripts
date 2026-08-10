#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Mcanon
# License: MIT | https://github.com/24dubstep/ProxmoxVE-Helper-Scripts/raw/main/LICENSE
# Source: https://github.com/mek-yt/obs-server

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt-get update
$STD apt-get install -y \
  software-properties-common \
  ffmpeg \
  obs-studio \
  xfce4 \
  xfce4-goodies \
  chromium-browser \
  git \
  curl \
  wget \
  xvfb \
  x11vnc \
  novnc \
  websockify \
  dbus-x11 \
  pulseaudio \
  alsa-utils
msg_ok "Installed Dependencies"

setup_hwaccel

msg_info "Configuring OBS Server Second Desktop Environment"
ln -sf /usr/share/novnc/vnc.html /usr/share/novnc/index.html

cat <<'EOF' >/usr/local/bin/start-obs-server-second.sh
#!/usr/bin/env bash
export DISPLAY=:1
export HOME=/root

rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

Xvfb :1 -screen 0 1280x1024x24 &
sleep 2

startxfce4 &
sleep 2

x11vnc -display :1 -forever -shared -nopw -rfbport 5901 -bg
sleep 1

websockify --web /usr/share/novnc 6901 localhost:5901 &

exec obs
EOF
chmod +x /usr/local/bin/start-obs-server-second.sh
msg_ok "Configured OBS Server Second Desktop Environment"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/obs-server-second.service
[Unit]
Description=Headless OBS Server Second with XFCE & VNC
After=network.target

[Service]
Type=simple
Environment=DISPLAY=:1
Environment=HOME=/root
ExecStart=/usr/local/bin/start-obs-server-second.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl enable -q --now obs-server-second.service
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
