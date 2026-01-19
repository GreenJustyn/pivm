#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_guest_autoupdate.sh
# Description: This script automates the process of updating all running LXC
#              containers on a Proxmox server. It logs the entire update
#              process for each container.
#
# Execution: This script is designed to be run as a systemd timer.
#
# Copyright: (c) 2024, Justyn Green
# License: ISC
#
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Source common library and variables ---
cd "$(dirname "$0")"
source ./common.lib
eval $(jq -r '.proxmox_guest_autoupdate | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' ./variables.json)

# --- Functions ---
# (log function is provided by common.lib)

update_lxc_container() {
    local vmid=$1
    log "INFO" "Starting update for LXC container $vmid."
    
    if safe_exec pct exec "$vmid" -- bash -c "apt-get update && apt-get upgrade -y"; then
        log "INFO" "Successfully updated LXC container $vmid."
    else
        log "ERROR" "Failed to update LXC container $vmid."
    fi
    
    log "INFO" "Finished update for LXC container $vmid."
}

# --- Main Execution ---
log "INFO" "Starting LXC container update process..."

# Ensure log file and directory exist
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

# Get all running LXC containers
running_lxcs=$(safe_exec pct list | awk 'NR>1 && $2=="running" {print $1}')

if [ -z "$running_lxcs" ]; then
    log "INFO" "No running LXC containers found."
else
    for vmid in $running_lxcs; do
        update_lxc_container "$vmid"
    done
fi

log "INFO" "LXC container update process finished."

exit 0