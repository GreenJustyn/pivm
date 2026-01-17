#!/bin/bash
source /root/iac/common.lib
eval $(jq -r '.proxmox_vm_storage | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' /root/iac/variables.json)
