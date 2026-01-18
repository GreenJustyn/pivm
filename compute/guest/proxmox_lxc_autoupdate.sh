#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_lxc_autoupdate.sh
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
source /root/iac/common.lib
eval $(jq -r '.proxmox_lxc_autoupdate | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' /root/iac/variables.json)

# --- Functions ---
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

update_lxc_container() {
    local vmid=$1
    log_message "Starting update for LXC container $vmid."
    
    if pct exec "$vmid" -- bash -c "apt-get update && apt-get upgrade -y"; then
        log_message "Successfully updated LXC container $vmid."
    else
        log_message "ERROR: Failed to update LXC container $vmid."
    fi
    
    log_message "Finished update for LXC container $vmid."
}

# --- Main Execution ---
log_message "Starting LXC container update process..."

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Get all running LXC containers
running_lxcs=$(pct list | awk 'NR>1 && $2=="running" {print $1}')

if [ -z "$running_lxcs" ]; then
    log_message "No running LXC containers found."
else
    for vmid in $running_lxcs; do
        update_lxc_container "$vmid"
    done
fi

log_message "LXC container update process finished."

exit 0