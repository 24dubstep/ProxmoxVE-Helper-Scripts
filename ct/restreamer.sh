#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/24dubstep/ProxmoxVE-Helper-Scripts/main/misc/build.func)
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Mcanon
# License: MIT | https://github.com/24dubstep/ProxmoxVE-Helper-Scripts/raw/main/LICENSE
# Source: https://datarhei.org/
# Source: https://github.com/datarhei/restreamer
# Source: https://docs.datarhei.com/restreamer/
# Source: https://www.docker.com/
# Source: https://github.com/NVIDIA/nvidia-container-toolkit

APP="Restreamer"
var_tags="${var_tags:-media;streaming;restreamer;gpu}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-4096}"
var_disk="${var_disk:-16}"
var_os="${var_os:-ubuntu}"
var_version="${var_version:-24.04}"
var_unprivileged="${var_unprivileged:-1}"
var_gpu="${var_gpu:-yes}"

function header_info() {
  clear
  cat << "EOF"
 [32m  ____           _                                       [0m
 [32m |  _ \ ___  ___| |_ _ __ ___  __ _ _ __ ___   ___ _ __  [0m
 [32m | |_) / _ \/ __| __| '__/ _ \/ _` | '_ ` _ \ / _ \ '__| [0m
 [32m |  _ <  __/\__ \ |_| | |  __/ (_| | | | | | |  __/ |    [0m
 [32m |_| \_\___||___/\__|_|  \___|\__,_|_| |_| |_|\___|_|    [0m
                                                        
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
  if ! pct exec "${CTID}" -- docker ps -a | grep -q "restreamer"; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi
  msg_info "Updating ${APP}"
  pct exec "${CTID}" -- bash -c "docker pull datarhei/restreamer:latest && docker pull datarhei/restreamer:cuda-latest 2>/dev/null || true"
  pct exec "${CTID}" -- systemctl restart restreamer.service
  msg_ok "Updated ${APP}"
  exit
}

# ==============================================================================
# PRE-FLIGHT PROMPTS (Admin Credentials & GPU Driver Path)
# ==============================================================================
echo -e "\n${INFO}${YW}Restreamer Admin Credentials Setup${CL}"
read -r -p "${TAB}Enter Admin Username [default: admin]: " RESTREAMER_USER
RESTREAMER_USER="${RESTREAMER_USER:-admin}"

read -r -p "${TAB}Enter Admin Password [default: admin123]: " RESTREAMER_PASS
RESTREAMER_PASS="${RESTREAMER_PASS:-admin123}"

DEFAULT_GPU_DRIVER="/root/proxmox-vgpu-installer/guest-drivers/16.9_535.230.02/NVIDIA-Linux-x86_64-535.230.02-grid.run"

echo -e "\n${INFO}${YW}GPU Driver Installation (CUDA / NVENC)${CL}"
echo -e "${TAB}${INFO}${YW}Provide host path for guest GPU driver to install BEFORE NVIDIA/CUDA checks.${CL}"

read -r -p "${TAB}Enter GPU driver file path [default: ${DEFAULT_GPU_DRIVER}]: " GPU_DRIVER_INPUT
GPU_DRIVER_PATH="${GPU_DRIVER_INPUT:-${DEFAULT_GPU_DRIVER}}"
GPU_DRIVER_PATH="$(echo "${GPU_DRIVER_PATH}" | xargs)"

# ==============================================================================
# BUILD LXC CONTAINER
# ==============================================================================
start
build_container

# Save credentials into LXC environment script
pct exec "${CTID}" -- bash -c "cat <<EOF >/etc/restreamer.env
RS_USERNAME=${RESTREAMER_USER}
RS_PASSWORD=${RESTREAMER_PASS}
EOF"

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
      msg_info "Installing NVIDIA CUDA 12 Toolkit in container"
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
      msg_info "Cleaning conflicting apt NVIDIA packages in container"
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

      # Configure NVIDIA Container Toolkit inside LXC
      pct exec "${CTID}" -- bash -c "nvidia-ctk runtime configure --runtime=docker 2>/dev/null && systemctl restart docker 2>/dev/null" || true

      # Check nvidia-smi AFTER .run installation
      if pct exec "${CTID}" -- bash -c "nvidia-smi" >/dev/null 2>&1; then
        msg_ok "NVIDIA GPU driver & CUDA verified (nvidia-smi active)"
      else
        msg_warn "GPU driver pushed and install attempted — verify GPU passthrough in LXC config"
      fi

      # Cleanup pushed file
      pct exec "${CTID}" -- rm -f "${DRIVER_DEST}" 2>/dev/null || true
    else
      msg_error "Failed to push driver file into container"
    fi
  fi
else
  echo -e "${TAB}${INFO}${YW}No GPU driver specified — skipping.${CL}"
fi

# Restart Restreamer service AFTER GPU driver installation
pct exec "${CTID}" -- bash -c "systemctl restart restreamer.service 2>/dev/null" || true

# Update credentials.txt with container IP and credentials
pct exec "${CTID}" -- bash -c "cat <<EOF >/opt/restreamer/credentials.txt
==============================================================================
  Datarhei Restreamer LXC — Credentials & Access Info
==============================================================================

[Access URLs & Ports]
- Restreamer Web Interface:        http://${IP}:8080
- Restreamer HTTPS Interface:      https://${IP}:8181
- RTMP Stream Ingest URL:           rtmp://${IP}:1935/live/stream
- RTMPS Ingest URL:                 rtmps://${IP}:1936/live/stream
- SRT Stream Ingest URL:            srt://${IP}:6000

[Admin Login Credentials]
- Username:                         ${RESTREAMER_USER}
- Password:                         ${RESTREAMER_PASS}

[Storage Directories]
- Restreamer Application Root:      /opt/restreamer
- Configuration Directory:          /opt/restreamer/config
- Data Volume Directory:            /opt/restreamer/data
- Launcher Script:                  /opt/restreamer/scripts/start-restreamer.sh
- Credentials File:                 /opt/restreamer/credentials.txt
==============================================================================
EOF" 2>/dev/null || true

description

msg_ok "Completed successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}\n"
echo -e "${TAB}──────────────────────────────────────────────────────────────────"
echo -e "${TAB}${INFO}${YW} Restreamer Web Interface:${CL} ${GATEWAY}${BGN}http://${IP}:8080${CL}"
echo -e "${TAB}${INFO}${YW} Admin Username:${CL}           ${GATEWAY}${BGN}${RESTREAMER_USER}${CL}"
echo -e "${TAB}${INFO}${YW} Admin Password:${CL}           ${GATEWAY}${BGN}${RESTREAMER_PASS}${CL}"
echo -e "${TAB}${INFO}${YW} RTMP Stream Ingest URL:${CL}   ${GATEWAY}${BGN}rtmp://${IP}:1935/live/stream${CL}"
echo -e "${TAB}${INFO}${YW} SRT Stream Ingest URL:${CL}    ${GATEWAY}${BGN}srt://${IP}:6000${CL}"
echo -e "${TAB}${INFO}${YW} System Credentials File:${CL}  ${GATEWAY}${BGN}/opt/restreamer/credentials.txt${CL}"
echo -e "${TAB}──────────────────────────────────────────────────────────────────\n"
