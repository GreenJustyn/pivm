#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_autoupdate.sh
# Description: This script automates the process of updating the Proxmox host
#              OS and reboots if necessary.
#
# Execution: This script is designed to be run as a systemd timer.
#
# Copyright: (c) 2024, Justyn Green
# License: ISC
#
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Source common library and variables ---
source /root/iac/common.lib
eval $(jq -r '.proxmox_autoupdate | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' /root/iac/variables.json)

# --- Main Execution ---
log "INFO" "Starting Proxmox host OS update process..."

# Ensure log file and directory exist
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Check for updates and perform upgrade
log "INFO" "Running apt update..."
if safe_exec apt update; then
    log "INFO" "apt update completed."
    
    log "INFO" "Checking for pending upgrades..."
    if apt list --upgradable | grep -q upgradable; then
        log "INFO" "Pending upgrades found. Running apt upgrade -y..."
        if safe_exec apt upgrade -y; then
            log "INFO" "apt upgrade completed."
            
            # Check if reboot is required (e.g., /var/run/reboot-required exists)
            if [ -f /var/run/reboot-required ]; then
                log "WARN" "Reboot required after upgrade. Rebooting system..."
                if [[ "${DRY_RUN:-false}" == "false" ]]; then
                    # Using shutdown instead of reboot for more controlled reboot behavior.
                    # 'shutdown -r now' is equivalent to 'reboot'
                    safe_exec /sbin/shutdown -r now
                else
                    log "INFO" "DRY_RUN: Reboot would have occurred."
                fi
            else
                log "INFO" "No reboot required after upgrade."
            fi
        else
            log "ERROR" "apt upgrade failed."
        fi
    else
        log "INFO" "No pending upgrades found."
    fi
else
    log "ERROR" "apt update failed."
fi

log "INFO" "Proxmox host OS update process finished."

exit 0