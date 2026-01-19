#!/bin/bash
# -----------------------------------------------------------------------------
# Script: uninstall.sh
# Description: Uninstalls the Proxmox IaC scripts and all related files.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
# Source variables from JSON file if it exists
if [ -f "variables.json" ]; then
    eval $(jq -r '.uninstall | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' variables.json)
else
    # Set default values if variables.json is missing
    INSTALL_DIR="/root/iac"
    SVC_IAC="proxmox-iac"
    SVC_HOST_UP="proxmox-autoupdate"
    SVC_GUEST_UP="proxmox-guest-autoupdate"
    SVC_ISO="proxmox-iso-sync"
fi


echo ">>> Starting Proxmox IaC Uninstallation..."

# 1. Stop and Disable Systemd Timers and Services
echo "--- Disabling and removing Systemd units ---"
SERVICES=("${SVC_IAC}" "${SVC_HOST_UP}" "${SVC_GUEST_UP}" "${SVC_ISO}")
for service in "${SERVICES[@]}"; do
    if systemctl list-units --full -all | grep -Fq "${service}.timer"; then
        echo "Stopping and disabling ${service}.timer"
        systemctl disable --now "${service}.timer"
        rm -f "/etc/systemd/system/${service}.timer"
    fi
    if systemctl list-units --full -all | grep -Fq "${service}.service"; then
        echo "Stopping and disabling ${service}.service"
        systemctl stop "${service}.service"
        rm -f "/etc/systemd/system/${service}.service"
    fi
done

# 2. Cleanup Old Processes
echo "--- Stopping Running Processes ---"
pkill -9 -f "proxmox_dsc.sh" || true
pkill -9 -f "proxmox_autoupdate.sh" || true
pkill -9 -f "proxmox_guest_autoupdate.sh" || true
pkill -9 -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock

# 3. Remove Installed Files
echo "--- Removing Installed Files ---"
rm -rf "$INSTALL_DIR"
rm -f /etc/logrotate.d/proxmox_iac

# 4. Reload Systemd
echo "--- Reloading Systemd ---"
systemctl daemon-reload

echo ">>> Uninstallation Complete."
