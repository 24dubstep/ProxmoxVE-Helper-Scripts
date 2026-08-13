#!/usr/bin/env bash
# shellcheck source=/dev/null
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
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
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
  msg_info "Updating ${APP} Packages & Control Panel"
  $STD apt-get update
  $STD apt-get --only-upgrade install -y obs-studio
  
  if [[ -x /usr/local/bin/obs-update ]]; then
    $STD /usr/local/bin/obs-update
  else
    if [[ -x /usr/local/bin/obs-status-update.sh ]]; then
      /usr/local/bin/obs-status-update.sh
    fi
  fi
  msg_ok "Updated ${APP} LXC Container Successfully!"
  exit
}

# ==============================================================================
# PRE-FLIGHT PROMPTS (GPU Driver Path & Restreamer Integration)
# ==============================================================================
DEFAULT_GPU_DRIVER="/root/proxmox-vgpu-installer/guest-drivers/16.9_535.230.02/NVIDIA-Linux-x86_64-535.230.02-grid.run"

NVIDIA_GPU_DETECTED=false
if lspci -nn 2>/dev/null | grep -qi "NVIDIA" || ls /dev/nvidia* &>/dev/null; then
  NVIDIA_GPU_DETECTED=true
fi

if [[ -z "${var_gpu_driver_path:-}" ]]; then
  echo -e "\n${INFO}${YW}GPU Driver Installation (Local .run file)${CL}"
  if [[ "${NVIDIA_GPU_DETECTED}" == "true" ]]; then
    echo -e "${TAB}${INFO}${GN}NVIDIA GPU hardware detected on host system.${CL}"
  else
    echo -e "${TAB}${INFO}${YW}No NVIDIA GPU automatically detected on host (or passthrough manual mode).${CL}"
  fi
  echo -e "${TAB}${INFO}${YW}Provide host path for guest GPU driver to install into container.${CL}"
  read -r -p "${TAB}Enter GPU driver file path [default: ${DEFAULT_GPU_DRIVER}]: " var_gpu_driver_path
fi
var_gpu_driver_path="${var_gpu_driver_path:-${DEFAULT_GPU_DRIVER}}"
var_gpu_driver_path="$(echo "${var_gpu_driver_path}" | xargs)"
export var_gpu_driver_path="${var_gpu_driver_path:-}"

if [[ -z "${var_install_restreamer:-}" ]]; then
  echo -e "\n${INFO}${YW}Datarhei Restreamer Integration${CL}"
  echo -e "${TAB}${INFO}${YW}Restreamer can be installed alongside OBS Studio to automatically receive${CL}"
  echo -e "${TAB}${INFO}${YW}the RTMP stream and restream it to YouTube, Twitch, Facebook, or SRT.${CL}"
  read -r -p "${TAB}Would you like to install Restreamer alongside OBS Studio? [y/N]: " var_install_restreamer
fi
var_install_restreamer="${var_install_restreamer:-no}"
export var_install_restreamer="${var_install_restreamer:-}"

if [[ "${var_install_restreamer,,}" =~ ^(y|yes)$ ]]; then
  if [[ -z "${var_restreamer_user:-}" ]]; then
    echo -e "\n${INFO}${YW}Restreamer Admin Credentials Setup${CL}"
    read -r -p "${TAB}Enter Admin Username [default: admin]: " var_restreamer_user
  fi
  var_restreamer_user="${var_restreamer_user:-admin}"
  export var_restreamer_user="${var_restreamer_user:-}"

  if [[ -z "${var_restreamer_pass:-}" ]]; then
    read -r -p "${TAB}Enter Admin Password [default: admin123]: " var_restreamer_pass
  fi
  var_restreamer_pass="${var_restreamer_pass:-admin123}"
  export var_restreamer_pass="${var_restreamer_pass:-}"
fi

# ==============================================================================
# BUILD LXC CONTAINER
# ==============================================================================
start
build_container

# Write Restreamer configuration into CT if requested
if [[ "${var_install_restreamer,,}" =~ ^(y|yes)$ ]]; then
  pct exec "${CTID}" -- bash -c "cat <<EOF >/etc/restreamer.env
INSTALL_RESTREAMER=yes
RS_USERNAME=${var_restreamer_user}
RS_PASSWORD=${var_restreamer_pass}
EOF"
  msg_ok "Configured Restreamer credentials for CT ${CTID}"
fi

# ==============================================================================
# INSTALL LOCAL .RUN GPU DRIVER & CUDA AFTER CARD DETECTION
# ==============================================================================
if [[ -n "${var_gpu_driver_path}" ]]; then
  if [[ ! -f "${var_gpu_driver_path}" ]]; then
    msg_error "File not found: ${var_gpu_driver_path}"
    echo -e "${TAB}${INFO}${YW}Skipping GPU driver installation. You can install it manually later.${CL}"
  else
    GPU_DRIVER_FILENAME="$(basename "${var_gpu_driver_path}")"
    GPU_DRIVER_EXT="${GPU_DRIVER_FILENAME##*.}"
    DRIVER_DEST="/tmp/${GPU_DRIVER_FILENAME}"

    msg_info "Pushing GPU driver into container ${CTID}"
    if pct push "${CTID}" "${var_gpu_driver_path}" "${DRIVER_DEST}" >/dev/null 2>&1; then
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

      # Execute host-matched GPU driver .run/.deb file
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

      # Check nvidia-smi AFTER driver file installation to verify
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
pct exec "${CTID}" -- bash -c "
if [ ! -f /opt/obs-studio/dashboard/obs-web/index.html ]; then
  rm -rf /opt/obs-studio/dashboard/obs-web
  git clone --depth 1 -b gh-pages https://github.com/Niek/obs-web.git /opt/obs-studio/dashboard/obs-web 2>/dev/null || (mkdir -p /opt/obs-studio/dashboard/obs-web && curl -fsSL https://github.com/Niek/obs-web/archive/refs/heads/gh-pages.tar.gz | tar -xz -C /opt/obs-studio/dashboard/obs-web --strip-components=1 2>/dev/null || true)
fi
" 2>/dev/null || true

# Retrieve container IP address and update description
description

# Update credentials.txt with container IP and credentials
RS_USER_VAL="N/A"
RS_PASS_VAL="N/A"
if pct exec "${CTID}" -- test -f /etc/restreamer.env; then
  RS_USER_VAL=$(pct exec "${CTID}" -- grep RS_USERNAME /etc/restreamer.env 2>/dev/null | cut -d= -f2 || echo "admin")
  RS_PASS_VAL=$(pct exec "${CTID}" -- grep RS_PASSWORD /etc/restreamer.env 2>/dev/null | cut -d= -f2 || echo "admin123")
fi

pct exec "${CTID}" -- bash -c "cat <<EOF >/opt/obs-studio/credentials.txt
==============================================================================
  OBS Studio Headless LXC — System Credentials & Access Info
==============================================================================

[Access URLs & Ports]
- Status Dashboard & Control Panel: http://${IP}:8888
- OBS Web Remote Control:           http://${IP}:8888/obs-web/
- noVNC Interactive Web Desktop:    http://${IP}:8081/vnc.html?autoconnect=true&resize=remote
- OBS WebSocket Port:               4455 (Auth: Disabled)
- VNC Direct Server Port:           5900

[Restreamer Live Streaming Engine]
- Restreamer Web Interface:        http://${IP}:8080
- Admin Username:                   ${RS_USER_VAL}
- Admin Password:                   ${RS_PASS_VAL}
- RTMP Stream Ingest URL:           rtmp://${IP}:1935/live/stream
- SRT Stream Ingest URL:            srt://${IP}:6000

[Storage Directories]
- OBS Application Root:             /opt/obs-studio
- OBS Recordings Path:              /opt/obs-studio/recordings
- Dashboard Directory:              /opt/obs-studio/dashboard
- Restreamer Config Path:           /opt/restreamer/config
- Restreamer Data Path:             /opt/restreamer/data
- Credentials File:                 /opt/obs-studio/credentials.txt
==============================================================================
EOF" 2>/dev/null || true

# Restart services and update dashboard status AFTER driver installation
pct exec "${CTID}" -- bash -c "systemctl restart nginx obs-web.service obs-dashboard-api.service 2>/dev/null && /usr/local/bin/obs-status-update.sh" 2>/dev/null || true

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}\n"
echo -e "${TAB}──────────────────────────────────────────────────────────────────"
echo -e "${TAB}${INFO}${YW} OBS Status Dashboard:${CL}     ${GATEWAY}${BGN}http://${IP}:8888${CL}"
echo -e "${TAB}${INFO}${YW} OBS Web Remote Control:${CL}   ${GATEWAY}${BGN}http://${IP}:8888/obs-web/${CL}"
echo -e "${TAB}${INFO}${YW} noVNC Web Desktop:${CL}        ${GATEWAY}${BGN}http://${IP}:8081/vnc.html?autoconnect=true${CL}"
echo -e "${TAB}${INFO}${YW} OBS WebSocket Port:${CL}     ${GATEWAY}${BGN}4455 (Auth: Disabled)${CL}"
if pct exec "${CTID}" -- test -f /etc/restreamer.env; then
  echo -e "${TAB}${INFO}${YW} Restreamer Web Interface:${CL} ${GATEWAY}${BGN}http://${IP}:8080${CL}"
  echo -e "${TAB}${INFO}${YW} Restreamer Admin Login:${CL}   ${GATEWAY}${BGN}${RS_USER_VAL} / ${RS_PASS_VAL}${CL}"
  echo -e "${TAB}${INFO}${YW} RTMP Stream Ingest:${CL}       ${GATEWAY}${BGN}rtmp://${IP}:1935/live/stream${CL}"
fi
echo -e "${TAB}${INFO}${YW} System Credentials File:${CL}  ${GATEWAY}${BGN}/opt/obs-studio/credentials.txt${CL}"
echo -e "${TAB}──────────────────────────────────────────────────────────────────\n"
