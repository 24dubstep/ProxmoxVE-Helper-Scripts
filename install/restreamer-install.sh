#!/usr/bin/env bash

# Copyright (c) 2021-2026 community-scripts ORG
# Author: Mcanon
# License: MIT | https://github.com/24dubstep/ProxmoxVE-Helper-Scripts/raw/main/LICENSE
# Source: https://datarhei.org/
# Source: https://github.com/datarhei/restreamer
# Source: https://docs.datarhei.com/restreamer/
# Source: https://www.docker.com/
# Source: https://github.com/NVIDIA/nvidia-container-toolkit

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# ==============================================================================
# GPU PASSTHROUGH (VAAPI / NVENC)
# Disable automatic apt NVIDIA driver installation; custom driver is pushed via host script.
# ==============================================================================
export INSTALL_NVIDIA_DRIVERS="no"
setup_hwaccel

# ==============================================================================
# DEPENDENCIES (Docker CE & NVIDIA Container Toolkit)
# ==============================================================================
msg_info "Installing Docker & NVIDIA Container Toolkit (CUDA support)"
$STD apt-get update
$STD apt-get install -y ca-certificates curl gnupg lsb-release jq procps git wget

# Install Docker CE
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null || true
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs 2>/dev/null || echo "noble") stable" > /etc/apt/sources.list.d/docker.list

$STD apt-get update
$STD apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

# Install NVIDIA Container Toolkit for CUDA & NVENC support in Docker
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg 2>/dev/null || true
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' > /etc/apt/sources.list.d/nvidia-container-toolkit.list

$STD apt-get update
$STD apt-get install -y nvidia-container-toolkit 2>/dev/null || true
nvidia-ctk runtime configure --runtime=docker >/dev/null 2>&1 || true
systemctl restart docker >/dev/null 2>&1 || true

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

msg_ok "Installed Docker, NVIDIA Container Toolkit & CUDA 12"

# ==============================================================================
# RESTREAMER START SCRIPT
# ==============================================================================
msg_info "Configuring Restreamer Service"

mkdir -p /opt/restreamer/config /opt/restreamer/data

cat <<'EOF' >/usr/local/bin/start-restreamer.sh
#!/usr/bin/env bash
export HOME=/root

# Detect GPU & CUDA availability
DOCKER_IMAGE="datarhei/restreamer:latest"
GPU_FLAGS=()

if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null; then
  DOCKER_IMAGE="datarhei/restreamer:cuda-latest"
  GPU_FLAGS+=("--gpus" "all")
elif [[ -e /dev/dri/renderD128 ]]; then
  DOCKER_IMAGE="datarhei/restreamer:vaapi-latest"
  GPU_FLAGS+=("--device" "/dev/dri:/dev/dri")
fi

# Load custom environment credentials if present
if [[ -f /etc/restreamer.env ]]; then
  source /etc/restreamer.env
fi

RS_USERNAME="${RS_USERNAME:-admin}"
RS_PASSWORD="${RS_PASSWORD:-admin123}"

mkdir -p /opt/restreamer/config /opt/restreamer/data

# Ensure clean container state
docker stop restreamer >/dev/null 2>&1 || true
docker rm restreamer >/dev/null 2>&1 || true

# Pull image if needed
docker pull "${DOCKER_IMAGE}" || true

# Run Restreamer
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

# ==============================================================================
# SYSTEMD SERVICE
# ==============================================================================
cat <<EOF >/etc/systemd/system/restreamer.service
[Unit]
Description=Datarhei Restreamer Live Streaming Server
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
msg_ok "Configured Restreamer Service"

motd_ssh
customize
cleanup_lxc
