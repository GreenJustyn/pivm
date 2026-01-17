#!/bin/bash
# -----------------------------------------------------------------------------
# Script: uninstall.sh
# Description: Uninstalls the Proxmox IaC scripts and all related files.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
INSTALL_DIR="/root/iac"
SVC_IAC="proxmox-iac"
SVC_HOST_UP="proxmox-autoupdate"
SVC_LXC_UP="proxmox-lxc-autoupdate"
SVC_ISO="proxmox-iso-sync"

echo ">>> Starting Proxmox Uninstallation..."

# 1. Stop and Disable Systemd Timers
echo "--- Disabling Systemd Timers ---"
systemctl disable --now ${SVC_IAC}.timer
systemctl disable --now ${SVC_HOST_UP}.timer
systemctl disable --now ${SVC_LXC_UP}.timer
systemctl disable --now ${SVC_ISO}.timer

# 2. Cleanup Old Processes
echo "--- Stopping Running Processes ---"
pkill -9 -f "proxmox_dsc.sh" || true
pkill -9 -f "proxmox_lxc_mgr.sh" || true
pkill -9 -f "proxmox_autoupdate.sh" || true
pkill -9 -f "proxmox_lxc_autoupdate.sh" || true
pkill -9 -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Remove Installed Files
echo "--- Removing Installed Files ---"
rm -rf "$INSTALL_DIR"
rm -f /etc/logrotate.d/proxmox_iac

# 4. Reload Systemd
systemctl daemon-reload

echo ">>> Uninstallation Complete."
