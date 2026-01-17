#!/bin/bash
source /root/iac/common.lib
eval $(jq -r '.proxmox_lxc_autoupdate | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' /root/iac/variables.json)
# This is a placeholder for proxmox_lxc_autoupdate.sh
# The setup script will patch this file.
echo "proxmox_lxc_autoupdate.sh"