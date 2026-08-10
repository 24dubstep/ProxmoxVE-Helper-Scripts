#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/24dubstep/ProxmoxVE-Helper-Scripts/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Mcanon
# License: MIT | https://github.com/24dubstep/ProxmoxVE-Helper-Scripts/raw/main/LICENSE
# Source: https://github.com/mek-yt/obs-server

APP="OBS-Server-Second"
var_tags="${var_tags:-media;desktop;streaming;obs-server}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_unprivileged="${var_unprivileged:-1}"
var_gpu="${var_gpu:-yes}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /usr/bin/obs ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating ${APP}"
  $STD apt-get update
  $STD apt-get --only-upgrade install -y obs-studio chromium-browser
  msg_ok "Updated ${APP}"
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access Web Console using:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:6901${CL}"
echo -e "${INFO}${YW}Direct VNC Port:${CL} ${BGN}5901${CL}"
