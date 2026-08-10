#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/24dubstep/ProxmoxVE-Helper-Scripts/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Mcanon
# License: MIT | https://github.com/24dubstep/ProxmoxVE-Helper-Scripts/raw/main/LICENSE
# Source: https://obsproject.com/

APP="OBS-Studio"
var_tags="${var_tags:-media;streaming;headless;gpu}"
var_cpu="${var_cpu:-6}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
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
  $STD apt-get --only-upgrade install -y obs-studio
  msg_ok "Updated ${APP}"

  if [[ -f /var/www/obs-dashboard/index.html ]]; then
    msg_info "Updating Dashboard Status Data"
    if [[ -x /usr/local/bin/obs-status-update.sh ]]; then
      /usr/local/bin/obs-status-update.sh
    fi
    msg_ok "Updated Dashboard"
  fi
  exit
}

start
build_container

# ==============================================================================
# GPU DRIVER PUSH (host → container)
# ==============================================================================
DEFAULT_GPU_DRIVER="/root/proxmox-vgpu-installer/guest-drivers/16.9_535.230.02/NVIDIA-Linux-x86_64-535.230.02-grid.run"

echo -e "\n${INFO}${YW}GPU Driver Installation${CL}"
echo -e "${TAB}${INFO}${YW}If you have a GPU driver package (.deb or .run) for the LXC guest,${CL}"
echo -e "${TAB}${INFO}${YW}provide the path on the Proxmox host to push it into the container.${CL}"

read -r -p "${TAB}Enter GPU driver file path [default: ${DEFAULT_GPU_DRIVER}]: " GPU_DRIVER_INPUT
GPU_DRIVER_PATH="${GPU_DRIVER_INPUT:-${DEFAULT_GPU_DRIVER}}"
GPU_DRIVER_PATH="$(echo "${GPU_DRIVER_PATH}" | xargs)"

if [[ -n "${GPU_DRIVER_PATH}" ]]; then
  if [[ ! -f "${GPU_DRIVER_PATH}" ]]; then
    msg_error "File not found: ${GPU_DRIVER_PATH}"
    echo -e "${TAB}${INFO}${YW}Skipping GPU driver installation. You can install it manually later.${CL}"
  else
    GPU_DRIVER_FILENAME="$(basename "${GPU_DRIVER_PATH}")"
    GPU_DRIVER_EXT="${GPU_DRIVER_FILENAME##*.}"
    DRIVER_DEST="/tmp/${GPU_DRIVER_FILENAME}"

    msg_info "Pushing GPU driver into container ${CTID}"
    if pct push "${CTID}" "${GPU_DRIVER_PATH}" "${DRIVER_DEST}" >/dev/null 2>&1; then
      msg_ok "Pushed ${GPU_DRIVER_FILENAME} into container"

      msg_info "Cleaning conflicting apt NVIDIA packages in container"
      pct exec "${CTID}" -- bash -c "apt-get remove --purge -y '*nvidia*' '*cuda*' 2>/dev/null || true" >/dev/null 2>&1

      msg_info "Installing GPU driver in container"
      case "${GPU_DRIVER_EXT}" in
        deb)
          pct exec "${CTID}" -- bash -c "dpkg -i '${DRIVER_DEST}' 2>&1 || apt-get install -f -y 2>&1" >/dev/null 2>&1
          ;;
        run)
          pct exec "${CTID}" -- bash -c "chmod +x '${DRIVER_DEST}' && '${DRIVER_DEST}' -s --accept-license --no-kernel-module --ui=none --no-drm --no-x-check --no-nouveau-check 2>&1" >/dev/null 2>&1
          ;;
        *)
          msg_warn "Unknown driver format '.${GPU_DRIVER_EXT}' — pushed to ${DRIVER_DEST} but not auto-installed"
          msg_info "Install it manually: pct exec ${CTID} -- bash -c 'your-install-command ${DRIVER_DEST}'"
          ;;
      esac

      # Verify installation
      if pct exec "${CTID}" -- bash -c "nvidia-smi >/dev/null 2>&1 || ls /dev/dri/renderD* >/dev/null 2>&1" 2>/dev/null; then
        msg_ok "GPU driver installed successfully"
      else
        msg_warn "GPU driver pushed and install attempted — verify GPU passthrough in LXC config"
        echo -e "${TAB}${INFO}${YW}Make sure your LXC config has GPU passthrough enabled:${CL}"
        echo -e "${TAB}${BGN}  lxc.cgroup2.devices.allow: c 226:* rwm${CL}"
        echo -e "${TAB}${BGN}  lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir${CL}"
      fi

      # Cleanup pushed file
      pct exec "${CTID}" -- rm -f "${DRIVER_DEST}" 2>/dev/null || true
    else
      msg_error "Failed to push driver file into container"
      echo -e "${TAB}${INFO}${YW}You can push it manually: pct push ${CTID} '${GPU_DRIVER_PATH}' ${DRIVER_DEST}${CL}"
    fi
  fi
else
  echo -e "${TAB}${INFO}${YW}No GPU driver specified — skipping.${CL}"
  echo -e "${TAB}${INFO}${YW}You can push a driver later: pct push ${CTID} /path/to/driver.deb /tmp/driver.deb${CL}"
fi

# Restart OBS service to pick up driver changes
pct exec "${CTID}" -- bash -c "systemctl restart obs-web.service 2>/dev/null" || true

description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access noVNC Desktop:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}Access Status Dashboard:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8888${CL}"
