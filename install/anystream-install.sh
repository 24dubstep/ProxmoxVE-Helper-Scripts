#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Mcanon
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://anystream.dev/ | Github: https://github.com/DrewCarlson/AnyStream

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

msg_info "Installing Dependencies"
$STD apt install -y ffmpeg
msg_ok "Installed Dependencies"

JAVA_VERSION="21" setup_java

msg_info "Installing AnyStream"
mkdir -p /opt/anystream/{storage,media}
USE_ORIGINAL_FILENAME="true" fetch_and_deploy_gh_release "anystream" "DrewCarlson/AnyStream" "singlefile" "latest" "/opt/anystream" "anystream-server*.jar"
mv /opt/anystream/anystream-server-*.jar /opt/anystream/anystream-server.jar 2>/dev/null || true
msg_ok "Installed AnyStream"

msg_info "Creating Service"
cat <<EOF >/etc/systemd/system/anystream.service
[Unit]
Description=AnyStream
After=syslog.target network.target

[Service]
Type=simple
WorkingDirectory=/opt/anystream/
ExecStart=/usr/bin/java -jar -Xmx1g anystream-server.jar
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl enable -q --now anystream
msg_ok "Created Service"

motd_ssh
customize
cleanup_lxc
