#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/24dubstep/ProxmoxVE-Helper-Scripts/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Mcanon
# License: MIT | https://github.com/24dubstep/ProxmoxVE-Helper-Scripts/raw/main/LICENSE
# Source: https://anystream.dev/ | Github: https://github.com/DrewCarlson/AnyStream

APP="AnyStream"
var_tags="${var_tags:-media}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-2048}"
var_disk="${var_disk:-8}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_arm64="${var_arm64:-yes}"
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources
  if [[ ! -f /opt/anystream/bin/anystream ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  if check_for_gh_release "anystream" "DrewCarlson/AnyStream" "v0.0.1-test"; then
    msg_info "Stopping Service"
    systemctl stop anystream
    msg_ok "Stopped Service"

    fetch_and_deploy_gh_release "anystream" "DrewCarlson/AnyStream" "prebuild" "v0.0.1-test" "/opt/anystream" "anystream-server-*.zip"

    msg_info "Starting Service"
    systemctl start anystream
    msg_ok "Started Service"
    msg_ok "Updated successfully!"
  fi
  exit
}

start
build_container
description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access it using the following URL:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8888${CL}"
