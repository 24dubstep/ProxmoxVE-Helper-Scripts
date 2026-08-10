#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/24dubstep/ProxmoxVE-Helper-Scripts/main/misc/build.func)
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

APP="OBS-Studio"
var_tags="${var_tags:-media;streaming;headless;gpu}"
var_cpu="${var_cpu:-6}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-20}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_unprivileged="${var_unprivileged:-1}"
var_gpu="${var_gpu:-yes}"

function header_info() {
  clear
  cat << "EOF"
 [32m   ____  ____  _____     _____ __            ___       [0m
 [32m  / __ \/ __ )/ ___/    / ___// /___  ______/ (_)___   [0m
 [32m / / / / __  /\__ \     \__ \/ __/ / / / __  / / __ \  [0m
 [32m/ /_/ / /_/ /___/ /    ___/ / /_/ /_/ / /_/ / / /_/ /  [0m
 [32m\____/_____//____/    /____/\__/\__,_/\__,_/_/\____/   [0m
                                                      
EOF
}

header_info
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

# ==============================================================================
# PRE-FLIGHT PROMPTS (GPU Driver Path & Restreamer Integration)
# ==============================================================================
DEFAULT_GPU_DRIVER="/root/proxmox-vgpu-installer/guest-drivers/16.9_535.230.02/NVIDIA-Linux-x86_64-535.230.02-grid.run"

echo -e "\n${INFO}${YW}GPU Driver Installation (Local .run file)${CL}"
echo -e "${TAB}${INFO}${YW}Provide host path for guest GPU driver to install BEFORE NVIDIA/CUDA checks.${CL}"

read -r -p "${TAB}Enter GPU driver file path [default: ${DEFAULT_GPU_DRIVER}]: " GPU_DRIVER_INPUT
GPU_DRIVER_PATH="${GPU_DRIVER_INPUT:-${DEFAULT_GPU_DRIVER}}"
GPU_DRIVER_PATH="$(echo "${GPU_DRIVER_PATH}" | xargs)"

echo -e "\n${INFO}${YW}Datarhei Restreamer Integration${CL}"
echo -e "${TAB}${INFO}${YW}Restreamer can be installed alongside OBS Studio to automatically receive${CL}"
echo -e "${TAB}${INFO}${YW}the RTMP stream and restream it to YouTube, Twitch, Facebook, or SRT.${CL}"

read -r -p "${TAB}Would you like to install Restreamer alongside OBS Studio? [y/N]: " INSTALL_RESTREAMER_INPUT

if [[ "${INSTALL_RESTREAMER_INPUT,,}" =~ ^(y|yes)$ ]]; then
  echo -e "\n${INFO}${YW}Restreamer Admin Credentials Setup${CL}"
  read -r -p "${TAB}Enter Admin Username [default: admin]: " RESTREAMER_USER
  RESTREAMER_USER="${RESTREAMER_USER:-admin}"

  read -r -p "${TAB}Enter Admin Password [default: admin123]: " RESTREAMER_PASS
  RESTREAMER_PASS="${RESTREAMER_PASS:-admin123}"
fi

# ==============================================================================
# BUILD LXC CONTAINER
# ==============================================================================
start
build_container

# Write Restreamer configuration into CT if requested
if [[ "${INSTALL_RESTREAMER_INPUT,,}" =~ ^(y|yes)$ ]]; then
  pct exec "${CTID}" -- bash -c "cat <<EOF >/etc/restreamer.env
INSTALL_RESTREAMER=yes
RS_USERNAME=${RESTREAMER_USER}
RS_PASSWORD=${RESTREAMER_PASS}
EOF"
  msg_ok "Configured Restreamer credentials for CT ${CTID}"
fi

# ==============================================================================
# INSTALL LOCAL .RUN GPU DRIVER & CUDA BEFORE VERIFICATION
# ==============================================================================
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

      # Install CUDA 12 Toolkit FIRST
      msg_info "Installing NVIDIA CUDA 12 Toolkit in container ${CTID}"
      pct exec "${CTID}" -- bash -c "
        KEYRING=\$(mktemp)
        if curl -fsSL -o \${KEYRING} https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb 2>/dev/null; then
          dpkg -i \${KEYRING} 2>/dev/null || true
        fi
        rm -f \${KEYRING}
        apt-get update 2>/dev/null || true
        apt-get install -y --no-install-recommends cuda-toolkit-12-0 nvidia-cuda-toolkit 2>/dev/null || apt-get install -y --no-install-recommends nvidia-cuda-toolkit 2>/dev/null || true
        cat <<'CUDAENV' >/etc/profile.d/cuda.sh
export PATH=/usr/local/cuda-12/bin:/usr/local/cuda/bin:\${PATH}
export LD_LIBRARY_PATH=/usr/local/cuda-12/lib64:/usr/local/cuda/lib64:\${LD_LIBRARY_PATH}
CUDAENV
        chmod +x /etc/profile.d/cuda.sh
      " >/dev/null 2>&1
      msg_ok "Installed CUDA 12 Toolkit"

      # Clean conflicting apt driver packages
      msg_info "Cleaning conflicting apt NVIDIA driver packages in container"
      pct exec "${CTID}" -- bash -c "apt-get remove --purge -y 'nvidia-driver-*' 'xserver-xorg-video-nvidia-*' 2>/dev/null || true" >/dev/null 2>&1

      # Execute host-matched GPU driver .run file LAST so its libraries remain active
      msg_info "Installing host-matched GPU driver (.run file) in container"
      case "${GPU_DRIVER_EXT}" in
        deb)
          pct exec "${CTID}" -- bash -c "dpkg -i '${DRIVER_DEST}' 2>&1 || apt-get install -f -y 2>&1" >/dev/null 2>&1
          ;;
        run)
          pct exec "${CTID}" -- bash -c "chmod +x '${DRIVER_DEST}' && '${DRIVER_DEST}' -s --accept-license --no-kernel-module --ui=none --no-drm --no-x-check --no-nouveau-check 2>&1" >/dev/null 2>&1
          ;;
        *)
          msg_warn "Unknown driver format '.${GPU_DRIVER_EXT}' — pushed to ${DRIVER_DEST} but not auto-installed"
          ;;
      esac

      # Check nvidia-smi AFTER .run installation
      if pct exec "${CTID}" -- bash -c "nvidia-smi" >/dev/null 2>&1; then
        msg_ok "NVIDIA GPU driver & NVENC verified (nvidia-smi active)"
        # Update OBS profile to use NVENC hardware encoder
        pct exec "${CTID}" -- bash -c "
          sed -i 's/StreamEncoder=.*/StreamEncoder=jim_nvenc/' /root/.config/obs-studio/basic/profiles/Headless/basic.ini 2>/dev/null || true
          sed -i 's/RecEncoder=.*/RecEncoder=jim_nvenc/' /root/.config/obs-studio/basic/profiles/Headless/basic.ini 2>/dev/null || true
        "
      else
        msg_warn "GPU driver pushed and install attempted — verify GPU passthrough in LXC config"
      fi

      # Cleanup pushed driver file
      pct exec "${CTID}" -- rm -f "${DRIVER_DEST}" 2>/dev/null || true
    else
      msg_error "Failed to push driver file into container"
    fi
  fi
fi

# Re-verify obs-studio package and obs-web files presence
pct exec "${CTID}" -- bash -c "which obs >/dev/null 2>&1 || (apt-get update && apt-get install -y obs-studio)" 2>/dev/null || true
pct exec "${CTID}" -- bash -c "if [ ! -f /var/www/obs-dashboard/obs-web/index.html ]; then git clone --depth 1 -b gh-pages https://github.com/Niek/obs-web.git /var/www/obs-dashboard/obs-web 2>/dev/null || true; fi" 2>/dev/null || true

# Restart services and update dashboard status AFTER driver installation
pct exec "${CTID}" -- bash -c "systemctl restart nginx obs-web.service && /usr/local/bin/obs-status-update.sh" 2>/dev/null || true

description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW}Access noVNC Desktop:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${INFO}${YW}Access Status Dashboard:${CL}"
echo -e "${GATEWAY}${BGN}http://${IP}:8888${CL}"
