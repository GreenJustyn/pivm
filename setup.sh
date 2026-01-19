#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh
# Version: 10.9
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

# 2. Cleanup Old Processes and Systemd Units
echo "--- Cleaning up existing Systemd units ---"
# Stop and disable timers and services to ensure clean re-installation
systemctl disable --now ${SVC_IAC}.timer || true
systemctl disable --now ${SVC_IAC}.service || true
systemctl disable --now ${SVC_HOST_UP}.timer || true
systemctl disable --now ${SVC_HOST_UP}.service || true
systemctl disable --now ${SVC_LXC_UP}.timer || true
systemctl disable --now ${SVC_LXC_UP}.service || true
systemctl disable --now ${SVC_ISO}.timer || true
systemctl disable --now ${SVC_ISO}.service || true
systemctl disable --now ${SVC_GUEST_MGR}.timer || true
systemctl disable --now ${SVC_GUEST_MGR}.service || true

# Kill any running script instances
pkill -9 -f "proxmox_dsc.sh" || true
pkill -9 -f "proxmox_lxc_mgr.sh" || true
pkill -9 -f "proxmox_autoupdate.sh" || true
pkill -9 -f "proxmox_lxc_autoupdate.sh" || true
pkill -9 -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock # Ensure lock file is removed

# 3. Install Scripts
echo "--- Installing Scripts ---"
cp -v "$REPO_DIR/bin/common.lib" "$INSTALL_DIR/"
cp -v "$REPO_DIR/bin/proxmox_wrapper.sh" "$INSTALL_DIR/"
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

# 5. Systemd Service and Timer
echo "--- Creating Systemd Service and Timer ---"
cat <<EOF > /etc/systemd/system/${SVC_IAC}.service
[Unit]
Description=Proxmox IaC GitOps Workflow
After=network.target

[Service]
ExecStart=$INSTALL_DIR/proxmox_wrapper.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/${SVC_IAC}.timer
[Unit]
Description=Run Proxmox IaC GitOps Workflow every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

# 7. Log Rotation
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

# 8. Systemd Timers
echo "--- Configuring Systemd Timers ---"
systemctl daemon-reload # Reload daemon to pick up any changes to unit files

systemctl enable --now ${SVC_IAC}.timer
systemctl enable --now ${SVC_HOST_UP}.timer
systemctl enable --now ${SVC_LXC_UP}.timer
systemctl enable --now ${SVC_ISO}.timer
systemctl enable --now ${SVC_GUEST_MGR}.timer

echo ">>> Installation Complete."
