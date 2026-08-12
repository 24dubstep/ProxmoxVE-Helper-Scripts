#!/usr/bin/env bash
# Proxmox VE LXC Setup Script for Antigravity Shield Enterprise
# Inspired by tteck / 24dubstep helper scripts
# Run this on your Proxmox Node shell.

set -e

echo -e "\e[1;36mStarting Installation of Antigravity Shield Enterprise LXC...\e[0m"

# Ensure pct exists (meaning we are on Proxmox)
if ! command -v pct &> /dev/null; then
    echo -e "\e[1;31mError: This script must be run on a Proxmox VE node.\e[0m"
    exit 1
fi

# 1. Dynamic CT ID Selection
CT_ID=240
if pct status $CT_ID &>/dev/null; then
    NEXT_ID=$(pvesh get /cluster/nextid 2>/dev/null || true)
    if [ -n "$NEXT_ID" ] && ! pct status "$NEXT_ID" &>/dev/null; then
        CT_ID=$NEXT_ID
    else
        while pct status $CT_ID &>/dev/null; do
            ((CT_ID++))
        done
    fi
fi

CT_NAME="antimalware-engine"
CORES=2
RAM=2048
DISK_SIZE="8G"
BRIDGE="vmbr0"
PASSWORD="antigravity"

# 2. Dynamic Storage Pool Selection
echo -e "\e[1;34mDetecting Proxmox storage pool...\e[0m"
STORAGE=""
for s in local-lvm local-zfs local storage pool; do
    if pvesm status -storage "$s" &>/dev/null; then
        STORAGE="$s"
        break
    fi
done
if [ -z "$STORAGE" ]; then
    STORAGE=$(pvesm status -content rootdir 2>/dev/null | awk 'NR>1 {print $1; exit}')
fi
if [ -z "$STORAGE" ]; then
    STORAGE="local-lvm"
fi
echo -e "\e[1;32m[+] Using storage pool: $STORAGE\e[0m"

# 3. Dynamic Template Resolution
echo -e "\e[1;34mUpdating template list and finding Debian 12 template...\e[0m"
pveam update || true

# Check if a template is already downloaded in storage
TEMPLATE_FILE=$(pveam list "$STORAGE" 2>/dev/null | grep -i "debian-12-standard" | tail -n 1 | awk '{print $2}')
if [ -z "$TEMPLATE_FILE" ]; then
    TEMPLATE_FILE=$(pveam list local 2>/dev/null | grep -i "debian-12-standard" | tail -n 1 | awk '{print $2}')
fi

if [ -z "$TEMPLATE_FILE" ]; then
    AVAIL_TMPL=$(pveam available -section system 2>/dev/null | grep -i "debian-12-standard" | tail -n 1 | awk '{print $2}')
    if [ -n "$AVAIL_TMPL" ]; then
        echo -e "\e[1;34mDownloading template $AVAIL_TMPL to $STORAGE...\e[0m"
        pveam download "$STORAGE" "$AVAIL_TMPL" || pveam download local "$AVAIL_TMPL" || true
        TEMPLATE_FILE="$STORAGE:vztmpl/$AVAIL_TMPL"
    else
        TEMPLATE_FILE="$STORAGE:vztmpl/debian-12-standard_12.2-1_amd64.tar.zst"
    fi
fi
echo -e "\e[1;32m[+] Using template: $TEMPLATE_FILE\e[0m"

echo -e "\e[1;34mCreating LXC Container $CT_ID...\e[0m"
pct create $CT_ID "$TEMPLATE_FILE" \
  --arch amd64 \
  --hostname $CT_NAME \
  --cores $CORES \
  --memory $RAM \
  --swap 512 \
  --rootfs "$STORAGE:$DISK_SIZE" \
  --net0 name=eth0,bridge=$BRIDGE,ip=dhcp \
  --password $PASSWORD \
  --unprivileged 1 \
  --features nesting=1

echo -e "\e[1;34mStarting Container $CT_ID...\e[0m"
pct start $CT_ID

echo -e "\e[1;34mWaiting for network initialization...\e[0m"
sleep 5

# 4. Push Codebase into LXC Container
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

pct exec $CT_ID -- mkdir -p /opt/antimalware-server

if [ -f "$REPO_DIR/server.py" ]; then
    echo -e "\e[1;34mPushing local application codebase to LXC container...\e[0m"
    tar -cf - -C "$REPO_DIR" --exclude='.git' --exclude='.venv' --exclude='__pycache__' . | pct exec $CT_ID -- tar -xf - -C /opt/antimalware-server
else
    echo -e "\e[1;34mNo local repository found. In-container script will git clone repository...\e[0m"
fi

# 5. Push or Fetch install_engine_lxc.sh from 24dubstep/ProxmoxVE-Helper-Scripts
INSTALLER_FETCH_URL="https://raw.githubusercontent.com/24dubstep/ProxmoxVE-Helper-Scripts/main/install/antimalware-server-install.sh"
INSTALLER_FALLBACK_URL="https://raw.githubusercontent.com/24dubstep/antimalware-server/main/scripts/install_engine_lxc.sh"

if [ -f "$SCRIPT_DIR/install_engine_lxc.sh" ]; then
    pct push $CT_ID "$SCRIPT_DIR/install_engine_lxc.sh" /tmp/install_engine_lxc.sh
elif [ -f "install_engine_lxc.sh" ]; then
    pct push $CT_ID install_engine_lxc.sh /tmp/install_engine_lxc.sh
else
    echo -e "\e[1;34mFetching installer script from ProxmoxVE-Helper-Scripts repository (24dubstep)...\e[0m"
    pct exec $CT_ID -- bash -c "wget -qO /tmp/install_engine_lxc.sh $INSTALLER_FETCH_URL || wget -qO /tmp/install_engine_lxc.sh $INSTALLER_FALLBACK_URL" || true
fi

if pct exec $CT_ID -- test -f /tmp/install_engine_lxc.sh; then
    echo -e "\e[1;34mExecuting installation script inside LXC...\e[0m"
    pct exec $CT_ID -- bash -c "chmod +x /tmp/install_engine_lxc.sh && /tmp/install_engine_lxc.sh"
elif pct exec $CT_ID -- test -f /opt/antimalware-server/scripts/install_engine_lxc.sh; then
    echo -e "\e[1;34mExecuting repository installation script inside LXC...\e[0m"
    pct exec $CT_ID -- bash -c "chmod +x /opt/antimalware-server/scripts/install_engine_lxc.sh && /opt/antimalware-server/scripts/install_engine_lxc.sh"
else
    echo -e "\e[1;33m[!] Warning: install_engine_lxc.sh not found. Running inline fallback setup...\e[0m"
    pct exec $CT_ID -- bash -c "apt-get update && apt-get install -y python3 python3-venv git curl && python3 -m venv /opt/antimalware-server/.venv && /opt/antimalware-server/.venv/bin/pip install fastapi uvicorn aiohttp requests"
fi

# 6. Retrieve IP Address
CT_IP=""
for i in {1..10}; do
    CT_IP=$(pct exec $CT_ID -- ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1 || true)
    if [ -n "$CT_IP" ]; then break; fi
    sleep 2
done

echo -e "\e[1;32mInstallation Complete!\e[0m"
if [ -n "$CT_IP" ]; then
    echo -e "Access the Web UI at: \e[1;36mhttp://$CT_IP:8000\e[0m"
else
    echo -e "\e[1;33mContainer started, but IP could not be auto-detected yet. Check 'pct exec $CT_ID -- ip a'\e[0m"
fi
echo -e "Container ID: $CT_ID"
echo -e "Default CT Password: $PASSWORD"

