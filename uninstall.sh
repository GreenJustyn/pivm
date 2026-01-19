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
# Find all proxmox timers, stop them, and remove the unit files
PROXMOX_TIMERS=$(systemctl list-unit-files --full | grep '^proxmox.*\.timer' --exclude={"proxmox-firewall*","proxmox-boot-cleanup*"} | awk '{print $1}' || true)

for timer in $PROXMOX_TIMERS; do
    service=${timer%.timer}.service

    echo "Stopping and disabling ${timer}"
    systemctl disable --now "${timer}" || true

    echo "Removing unit file: ${timer}"
    rm -f "/etc/systemd/system/${timer}"
    # Also try to remove from /usr/lib/systemd/system
    rm -f "/usr/lib/systemd/system/${timer}"

    # Stop the associated service
    if systemctl list-units --full -all | grep -Fq "${service}"; then
        echo "Stopping service ${service}"
        systemctl stop "${service}" || true
    fi
done

# Now, find all proxmox services, stop them, and remove the unit files
PROXMOX_SERVICES=$(systemctl list-unit-files --full | grep '^proxmox.*\.service' --exclude={"proxmox-firewall*","proxmox-boot-cleanup*"} | awk '{print $1}' || true)
for service in $PROXMOX_SERVICES; do
    # check if service file exists
    if [ -f "/etc/systemd/system/${service}" ] || [ -f "/usr/lib/systemd/system/${service}" ]; then
        echo "Stopping and disabling ${service}"
        systemctl disable "${service}" >/dev/null 2>&1 || true # May not be enabled
        systemctl stop "${service}" || true
        echo "Removing unit file: ${service}"
        rm -f "/etc/systemd/system/${service}"
        rm -f "/usr/lib/systemd/system/${service}"
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
