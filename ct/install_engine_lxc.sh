#!/usr/bin/env bash
# Installation script for Antigravity Shield Enterprise inside LXC
# Sets up Python, uv, SystemD, dependencies, and starts the service.

set -e

echo -e "\e[1;36m[+] Updating system packages...\e[0m"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-pip python3-venv curl git wget clamav clamav-daemon unzip tar

echo -e "\e[1;36m[+] Setting up Environment & PATH...\e[0m"
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

if ! command -v uv &>/dev/null; then
    echo -e "\e[1;36m[+] Installing uv (astral-sh) for fast Python package management...\e[0m"
    curl -LsSf https://astral.sh/uv/install.sh | sh || true
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
fi

APP_DIR="/opt/antimalware-server"
mkdir -p $APP_DIR
cd $APP_DIR

if [ ! -f "server.py" ]; then
    echo -e "\e[1;33m[!] server.py not found in $APP_DIR. Attempting git clone...\e[0m"
    git clone https://github.com/24dubstep/antimalware-server.git /tmp/antimalware-repo || true
    if [ -d "/tmp/antimalware-repo" ]; then
        cp -r /tmp/antimalware-repo/* $APP_DIR/
        rm -rf /tmp/antimalware-repo
    fi
fi

echo -e "\e[1;36m[+] Creating virtual environment and installing dependencies...\e[0m"
if command -v uv &>/dev/null; then
    uv venv .venv
    source .venv/bin/activate
    uv pip install fastapi uvicorn aiohttp python-multipart requests
else
    echo -e "\e[1;31m[!] uv not found. Using standard python3 venv & pip...\e[0m"
    python3 -m venv .venv
    source .venv/bin/activate
    pip install --upgrade pip
    pip install fastapi uvicorn aiohttp python-multipart requests
fi

echo -e "\e[1;36m[+] Fetching latest malware signatures...\e[0m"
mkdir -p signatures
wget -qO signatures/phpawmscan_sigs.json "https://raw.githubusercontent.com/marcocesarato/PHP-Antimalware-Scanner/master/src/Signatures/signatures.json" || echo "Failed to fetch phpawmscan signatures"

echo -e "\e[1;36m[+] Creating SystemD service...\e[0m"
cat <<EOF > /etc/systemd/system/antimalware-engine.service
[Unit]
Description=Antigravity Shield Enterprise Engine
After=network.target

[Service]
User=root
WorkingDirectory=$APP_DIR
Environment="PATH=$APP_DIR/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="HOST=0.0.0.0"
Environment="PORT=8000"
Environment="HEADLESS=1"
ExecStart=$APP_DIR/.venv/bin/python3 $APP_DIR/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable antimalware-engine
systemctl restart antimalware-engine || echo "Warning: systemctl restart returned non-zero (container init environment)"

echo -e "\e[1;32m[+] Engine installation inside LXC completed successfully!\e[0m"

