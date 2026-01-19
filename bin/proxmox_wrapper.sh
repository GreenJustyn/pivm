#!/bin/bash
# -----------------------------------------------------------------------------
# Script: proxmox_wrapper.sh
# Description: This wrapper script manages the GitOps workflow for Proxmox IaC.
# It ensures the latest version of the scripts is installed and then executes
# the main IaC script.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
# Source variables from JSON file
cd /root/iac
eval $(jq -r '.setup | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' variables.json)

LOG_FILE="/var/log/proxmox_master.log"

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

log ">>> Starting Proxmox IaC GitOps Workflow..."

# --- GitOps Workflow ---
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Git repository found. Checking for updates..."
    cd "$INSTALL_DIR"
    git fetch
    
    # Check for remote changes
    if [[ $(git rev-parse HEAD) != $(git rev-parse @{u}) ]]; then
        log "Changes detected in remote repository. Pulling and reinstalling..."
        git pull --force
        if [ -f "setup.sh" ]; then
            bash setup.sh
        else
            log "ERROR: setup.sh not found after pull."
            exit 1
        fi
        log "Re-installation complete."
    else
        log "No changes detected. Proceeding with execution."
    fi
else
    log "Git repository not found. Cloning from $REPO_URL..."
    rm -rf "$INSTALL_DIR"
    git clone "$REPO_URL" "$INSTALL_DIR"
    cd "$INSTALL_DIR"
    if [ -f "setup.sh" ]; then
        bash setup.sh
    else
        log "ERROR: setup.sh not found after clone."
        exit 1
    fi
    log "Initial installation complete."
fi

# --- Execute Main IaC Script ---
log "Executing main IaC script: proxmox_dsc.sh"
"$INSTALL_DIR/proxmox_dsc.sh"

log ">>> Proxmox IaC GitOps Workflow Finished."
