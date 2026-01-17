#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh
# Description: Installs and configures the Proxmox IaC scripts.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
# Source variables from JSON file
eval $(jq -r '.setup | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' variables.json)
REPO_DIR=$(pwd)

echo ">>> Starting Proxmox Installation..."

# 1. Dependency Check
apt-get update -qq
command -v jq >/dev/null 2>&1 || apt-get install -y jq
command -v git >/dev/null 2>&1 || apt-get install -y git
command -v wget >/dev/null 2>&1 || apt-get install -y wget

mkdir -p "$INSTALL_DIR"

# 2. Cleanup Old Processes
pkill -9 -f "proxmox_dsc.sh" || true
pkill -9 -f "proxmox_lxc_mgr.sh" || true
pkill -9 -f "proxmox_autoupdate.sh" || true
pkill -9 -f "proxmox_lxc_autoupdate.sh" || true
pkill -9 -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Install Scripts
echo "--- Installing Scripts ---"
cp -v "$REPO_DIR/common.lib" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/guest/proxmox_dsc.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/storage/host/proxmox_iso_sync.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/host/proxmox_autoupdate.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/guest/proxmox_lxc_autoupdate.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/network/guest/proxmox_lxc_network.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/storage/guest/proxmox_lxc_storage.sh" "$INSTALL_DIR/"

chmod +x "$INSTALL_DIR"/*.sh

# 4. Install JSON configuration files
echo "--- Installing JSON Configuration ---"
cp -v "$REPO_DIR/variables.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/guest/proxmox_dsc_state.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/host/proxmox_autoupdate.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/guest/proxmox_lxc_autoupdate.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/storage/host/proxmox_iso_sync.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/network/guest/proxmox_lxc_network_state.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/storage/guest/proxmox_lxc_storage_state.json" "$INSTALL_DIR/"

# 5. Log Rotation
cat <<EOF > /etc/logrotate.d/proxmox_iac
/var/log/proxmox_master.log
/var/log/proxmox_dsc.log 
/var/log/proxmox_autoupdate.log
/var/log/proxmox_lxc_autoupdate.log
/var/log/proxmox_iso_sync.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root root
    size 10M
}
EOF

# 6. Systemd Timers
systemctl daemon-reload
systemctl enable --now ${SVC_IAC}.timer
systemctl enable --now ${SVC_HOST_UP}.timer
systemctl enable --now ${SVC_LXC_UP}.timer
systemctl enable --now ${SVC_ISO}.timer

echo ">>> Installation Complete."
