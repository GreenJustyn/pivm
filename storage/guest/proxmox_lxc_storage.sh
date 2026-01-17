#!/bin/bash
source /root/iac/common.lib
eval $(jq -r '.proxmox_lxc_storage | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' /root/iac/variables.json)
# This is a placeholder for proxmox_lxc_storage.sh
echo "proxmox_lxc_storage.sh"
