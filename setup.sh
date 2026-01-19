#!/bin/bash
# -----------------------------------------------------------------------------
# Script: setup.sh
# Version: 11.0
# Description: Installs and configures the Proxmox IaC scripts.
# -----------------------------------------------------------------------------

set -euo pipefail

# --- Configuration ---
# Source variables from JSON file
eval $(jq -r '.setup | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' variables.json)
REPO_DIR=$(pwd)

echo ">>> Starting Proxmox IaC Installation..."

# 1. Dependency Check
echo "--- Checking dependencies ---"
apt-get update -qq
command -v jq >/dev/null 2>&1 || { echo "jq not found, installing..."; apt-get install -y jq; }
command -v git >/dev/null 2>&1 || { echo "git not found, installing..."; apt-get install -y git; }
command -v wget >/dev/null 2>&1 || { echo "wget not found, installing..."; apt-get install -y wget; }

# Create installation directory
echo "--- Creating installation directory ---"
mkdir -p "$INSTALL_DIR"
if [ ! -d "$INSTALL_DIR" ]; then
    echo "FATAL: Failed to create installation directory '$INSTALL_DIR'. Exiting."
    exit 1
fi

# 2. Cleanup Old Processes and Systemd Units
echo "--- Cleaning up existing processes and Systemd units ---"
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

# Kill any running script instances
pkill -9 -f "proxmox_dsc.sh" || true
pkill -9 -f "proxmox_autoupdate.sh" || true
pkill -9 -f "proxmox_guest_autoupdate.sh" || true
pkill -9 -f "proxmox_iso_sync.sh" || true
rm -f /tmp/proxmox_dsc.lock # Ensure lock file is removed

# 3. Install Scripts
echo "--- Installing Scripts ---"
cp -v "$REPO_DIR/bin/common.lib" "$INSTALL_DIR/"
cp -v "$REPO_DIR/bin/proxmox_wrapper.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/guest/proxmox_dsc.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/storage/host/proxmox_iso_sync.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/host/proxmox_autoupdate.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/guest/proxmox_guest_autoupdate.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/network/guest/proxmox_lxc_network.sh" "$INSTALL_DIR/"
cp -v "$REPO_DIR/storage/guest/proxmox_lxc_storage.sh" "$INSTALL_DIR/"

chmod +x "$INSTALL_DIR"/*.sh

# 4. Install JSON configuration files
echo "--- Installing JSON Configuration ---"
cp -v "$REPO_DIR/variables.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/guest/proxmox_dsc_state.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/host/proxmox_autoupdate.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/compute/guest/proxmox_guest_autoupdate.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/storage/host/proxmox_iso_sync.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/network/guest/proxmox_lxc_network_state.json" "$INSTALL_DIR/"
cp -v "$REPO_DIR/storage/guest/proxmox_lxc_storage_state.json" "$INSTALL_DIR/"

# 5. Create Systemd Service and Timer files
echo "--- Creating Systemd Service and Timer files ---"

# Service: Proxmox IaC GitOps Workflow
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

# Service: Proxmox Host Auto-Update
cat <<EOF > /etc/systemd/system/${SVC_HOST_UP}.service
[Unit]
Description=Proxmox Host Auto-Update
After=network.target

[Service]
ExecStart=$INSTALL_DIR/proxmox_autoupdate.sh

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/${SVC_HOST_UP}.timer
[Unit]
Description=Run Proxmox Host Auto-Update daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Service: Proxmox Guest Auto-Update
cat <<EOF > /etc/systemd/system/${SVC_GUEST_UP}.service
[Unit]
Description=Proxmox Guest Auto-Update
After=network.target

[Service]
ExecStart=$INSTALL_DIR/proxmox_guest_autoupdate.sh

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/${SVC_GUEST_UP}.timer
[Unit]
Description=Run Proxmox Guest Auto-Update weekly

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Service: Proxmox ISO Sync
cat <<EOF > /etc/systemd/system/${SVC_ISO}.service
[Unit]
Description=Proxmox ISO Sync
After=network.target

[Service]
ExecStart=$INSTALL_DIR/proxmox_iso_sync.sh

[Install]
WantedBy=multi-user.target
EOF

cat <<EOF > /etc/systemd/system/${SVC_ISO}.timer
[Unit]
Description=Run Proxmox ISO Sync daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 6. Log Rotation
echo "--- Configuring Log Rotation ---"
cat <<EOF > /etc/logrotate.d/proxmox_iac
/var/log/proxmox_master.log
/var/log/proxmox_dsc.log
/var/log/proxmox_autoupdate.log
/var/log/proxmox_guest_autoupdate.log
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

# 7. Enable and Start Systemd Timers
echo "--- Enabling and Starting Systemd Timers ---"
systemctl daemon-reload

for service in "${SERVICES[@]}"; do
    echo "Enabling and starting ${service}.timer"
    systemctl enable --now "${service}.timer"
done

echo ">>> Installation Complete."
