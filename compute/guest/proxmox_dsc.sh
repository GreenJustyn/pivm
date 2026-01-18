#!/bin/bash
source /root/iac/common.lib
eval $(jq -r '.proxmox_dsc | to_entries | .[] | "export " + .key + "=" + (.value | @sh)' /root/iac/variables.json)
MANIFEST=""
DRY_RUN=false
declare -a MANAGED_VMIDS=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --manifest) MANIFEST="$2"; shift ;; 
        --dry-run) DRY_RUN=true ;; 
    esac; shift
done

exec 200>"$LOCK_FILE"
flock -w 300 200 || { log "WARN" "Could not acquire lock after 300s. Exiting."; exit 1; }

get_resource_status() {
    local vmid=$1
    if safe_exec pct list 2>/dev/null | awk '{print $1}' | grep -q "^$vmid$"; then echo "exists_lxc"; return; fi
    if safe_exec qm list 2>/dev/null | awk '{print $1}' | grep -q "^$vmid$"; then echo "exists_vm"; return; fi
    echo "missing"
}

get_power_state() {
    local vmid=$1
    local type=$2
    if [[ "$type" == "lxc" ]]; then safe_exec pct status "$vmid" | awk '{print $2}'; else safe_exec qm status "$vmid" | awk '{print $2}'; fi
}

reconcile_cloudinit() {
    local vmid=$1
    local config=$2
    local storage=$3
    if [[ $(echo "$config" | jq -r ".cloud_init.enable") == "true" ]]; then
        local ci_user=$(echo "$config" | jq -r ".cloud_init.user")
        local ci_ssh=$(echo "$config" | jq -r ".cloud_init.sshkeys")
        local ci_ip=$(echo "$config" | jq -r ".cloud_init.ipconfig0")
        local cur_ide2=$(safe_exec qm config "$vmid" | grep "ide2:")
        local update_ci_settings=false
        
        if [[ -z "$cur_ide2" ]] || (echo "$cur_ide2" | grep -q "media=cdrom" && echo "$cur_ide2" | grep -q ".iso"); then
             log "WARN" "Drift $vmid: Cloud-Init drive missing or holding ISO. Fixing..."
             if [[ "$DRY_RUN" == "false" ]]; then
                 local store_name=$(echo "$storage" | awk -F: '{print $1}')
                 apply_and_restart "$vmid" "vm" qm "set --ide2 ${store_name}:cloudinit"
                 update_ci_settings=true
             fi
        fi
        local cur_ciuser=$(safe_exec qm config "$vmid" | grep "ciuser:" | awk "{print \$2}")
        if [[ "$cur_ciuser" != "$ci_user" ]]; then log "INFO" "Drift $vmid: Cloud-Init User/Settings mismatch."; update_ci_settings=true; fi
        if [[ "$update_ci_settings" == "true" ]]; then
             log "INFO" "Enforcing Cloud-Init Settings for VM $vmid..."
             if [[ "$DRY_RUN" == "false" ]]; then safe_exec qm set "$vmid" --ciuser "$ci_user" --sshkeys <(echo "$ci_ssh") --ipconfig0 "$ci_ip"; fi
        fi
    fi
}

reconcile_lxc() {
    local config="$1"
    local vmid=$(echo "$config" | jq -r '.vmid')
    local hostname=$(echo "$config" | jq -r '.hostname')
    local template=$(echo "$config" | jq -r '.template')
    local memory=$(echo "$config" | jq -r '.memory')
    local swap=$(echo "$config" | jq -r '.swap // 512')
    local cores=$(echo "$config" | jq -r '.cores')
    local storage=$(echo "$config" | jq -r '.storage')
    local net0=$(echo "$config" | jq -r '.net0')
    local onboot=$(echo "$config" | jq -r '.options.onboot // 0')
    local protection=$(echo "$config" | jq -r '.options.protection // 0')
    local desired_state=$(echo "$config" | jq -r '.state')

    log "INFO" "[LXC] Processing VMID: $vmid ($hostname)..."
    local status=$(get_resource_status "$vmid")

    if [[ "$status" == "missing" ]]; then
        log "WARN" "LXC $vmid missing. Creating..."
        if [[ "$DRY_RUN" == "false" ]]; then
            safe_exec pct create "$vmid" "$template" --hostname "$hostname" --memory "$memory" --swap "$swap" --cores "$cores" --net0 "$net0" --rootfs "$storage" --onboot "$onboot" --protection "$protection" --features nesting=1 || return 1
            log "SUCCESS" "LXC $vmid created."
        fi
    elif [[ "$status" == "exists_vm" ]]; then
        log "ERROR" "ID Conflict: $vmid is LXC but exists as VM."
        return 1
    else
        local cur_mem=$(safe_exec pct config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --memory $memory"; fi
        local cur_swap=$(safe_exec pct config "$vmid" | grep "swap:" | awk '{print $2}')
        if [[ "${cur_swap:-0}" != "$swap" ]]; then log "INFO" "Drift $vmid: Swap ${cur_swap:-0} -> $swap"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --swap $swap"; fi
        local cur_cores=$(safe_exec pct config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --cores $cores"; fi
        local cur_onboot=$(safe_exec pct config "$vmid" | grep "onboot:" | awk '{print $2}')
        if [[ "${cur_onboot:-0}" != "$onboot" ]]; then log "INFO" "Drift $vmid: OnBoot ${cur_onboot:-0} -> $onboot"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "lxc" pct "set --onboot $onboot"; fi
    fi

    local actual_state=$(get_power_state "$vmid" "lxc")
    if [[ "$desired_state" == "running" && "$actual_state" == "stopped" ]]; then
        log "INFO" "Starting LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then safe_exec pct start "$vmid"; fi
    elif [[ "$desired_state" == "stopped" && "$actual_state" == "running" ]]; then
        log "INFO" "Stopping LXC $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then safe_exec pct shutdown "$vmid"; fi
    fi
}

reconcile_vm() {
    local config="$1"
    local vmid=$(echo "$config" | jq -r '.vmid')
    local hostname=$(echo "$config" | jq -r '.hostname')
    local template=$(echo "$config" | jq -r '.template') # Can be ISO path OR Template ID
    local memory=$(echo "$config" | jq -r '.memory')
    local cores=$(echo "$config" | jq -r '.cores')
    local sockets=$(echo "$config" | jq -r '.sockets // 1')
    local cpu_type=$(echo "$config" | jq -r '.cpu // "kvm64"')
    local net0=$(echo "$config" | jq -r '.net0')
    local storage=$(echo "$config" | jq -r '.storage')
    local onboot=$(echo "$config" | jq -r '.options.onboot // 0')
    local protection=$(echo "$config" | jq -r '.options.protection // 0')
    local desired_state=$(echo "$config" | jq -r '.state')

    log "INFO" "[VM] Processing VMID: $vmid ($hostname)..."
    local status=$(get_resource_status "$vmid")

    if [[ "$status" == "missing" ]]; then
        log "WARN" "VM $vmid missing. Provisioning..."
        if [[ "$DRY_RUN" == "false" ]]; then
            # v10.0 CLONING SUPPORT
            if [[ "$template" =~ ^[0-9]+$ ]]; then
                log "ACTION" "Cloning from Template ID $template..."
                local store_target=$(echo "$storage" | awk -F: '{print $1}')
                safe_exec qm clone "$template" "$vmid" --name "$hostname" --full 1 --storage "$store_target"
                safe_exec qm set "$vmid" --memory "$memory" --cores "$cores" --sockets "$sockets" --cpu "$cpu_type" --net0 "$net0" --onboot "$onboot" --protection "$protection"
            else
                log "ACTION" "Creating Blank VM from ISO..."
                safe_exec qm create "$vmid" --name "$hostname" --memory "$memory" --cores "$cores" --sockets "$sockets" --cpu "$cpu_type" --net0 "$net0" --scsi0 "$storage" --cdrom "$template" --scsihw virtio-scsi-pci --boot order=scsi0;ide2;net0 --onboot "$onboot" --protection "$protection"
            fi
            
            if [[ $(echo "$config" | jq -r '.cloud_init.enable') == "true" ]]; then reconcile_cloudinit "$vmid" "$config" "$storage"; fi
            log "SUCCESS" "VM $vmid provisioned."
        fi
    elif [[ "$status" == "exists_lxc" ]]; then
        log "ERROR" "ID Conflict: $vmid is VM but exists as LXC."
        return 1
    else
        local cur_mem=$(safe_exec qm config "$vmid" | grep "memory:" | awk '{print $2}')
        if [[ "$cur_mem" != "$memory" ]]; then log "INFO" "Drift $vmid: Memory $cur_mem -> $memory"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --memory $memory"; fi
        local cur_cores=$(safe_exec qm config "$vmid" | grep "cores:" | awk '{print $2}')
        if [[ "$cur_cores" != "$cores" ]]; then log "INFO" "Drift $vmid: Cores $cur_cores -> $cores"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --cores $cores"; fi
        local cur_cpu=$(safe_exec qm config "$vmid" | grep "cpu:" | awk '{print $2}')
        if [[ "${cur_cpu:-kvm64}" != "$cpu_type" ]]; then log "WARN" "Drift $vmid: CPU Type ${cur_cpu:-kvm64} -> $cpu_type"; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --cpu $cpu_type"; fi
        local cur_net0=$(safe_exec qm config "$vmid" | grep "net0:" | awk '{$1=""; print $0}' | xargs)
        if [[ "$cur_net0" != "$net0" ]]; then log "INFO" "Drift $vmid: Network Config Changed."; [[ "$DRY_RUN" == "false" ]] && apply_and_restart "$vmid" "vm" qm "set --net0 $net0"; fi
        
        # v10.0 DISK RESIZE
        local req_size=$(echo "$storage" | awk -F: '{print $2}')
        local cur_size_raw=$(safe_exec qm config "$vmid" | grep "scsi0:" | grep -o "size=[0-9]*G" | grep -o "[0-9]*")
        if [[ -n "$req_size" && -n "$cur_size_raw" ]]; then
            if (( req_size > cur_size_raw )); then
                log "WARN" "Drift $vmid: Disk Size ${cur_size_raw}G -> ${req_size}G. Resizing..."
                [[ "$DRY_RUN" == "false" ]] && safe_exec qm resize "$vmid" scsi0 "${req_size}G"
            fi
        fi

        reconcile_cloudinit "$vmid" "$config" "$storage"
    fi

    local actual_state=$(get_power_state "$vmid" "vm")
    if [[ "$desired_state" == "running" && "$actual_state" == "stopped" ]]; then
        log "INFO" "Starting VM $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then safe_exec qm start "$vmid"; fi
    elif [[ "$desired_state" == "stopped" && "$actual_state" == "running" ]]; then
        log "INFO" "Stopping VM $vmid..."
        if [[ "$DRY_RUN" == "false" ]]; then safe_exec qm shutdown "$vmid"; fi
    fi
}

reconcile_dispatch() {
    local config="$1"
    local type=$(echo "$config" | jq -r '.type')
    local vmid=$(echo "$config" | jq -r '.vmid')
    MANAGED_VMIDS+=("$vmid")
    if [[ "$type" == "lxc" ]]; then reconcile_lxc "$config"; elif [[ "$type" == "vm" ]]; then reconcile_vm "$config"; fi
}

detect_unmanaged_workloads() {
    log "INFO" "Starting Audit for Unmanaged Workloads..."
    local lxc_list=$(safe_exec pct list 2>/dev/null | awk 'NR>1 {print $1}')
    local vm_list=$(safe_exec qm list 2>/dev/null | awk 'NR>1 {print $1}')
    local all_vms="${lxc_list}"$'\n'"${vm_list}"
    local found_foreign=false
    for host_vmid in $all_vms; do
        [[ -z "$host_vmid" ]] && continue
        local is_managed=false
        for managed_id in "${MANAGED_VMIDS[@]}"; do if [[ "$host_vmid" == "$managed_id" ]]; then is_managed=true; break; fi; done
        if [[ "$is_managed" == "false" ]]; then
            found_foreign=true
            log "WARN" "FOREIGN DETECTED: VMID $host_vmid"
        fi
    done
    if [[ "$found_foreign" == "true" ]]; then echo "FOREIGN WORKLOADS FOUND"; fi
}

log "INFO" "Run Started. Processing Manifest: $MANIFEST"
for row in $(cat "$MANIFEST" | jq -r '.[] | @base64'); do
    _jq() { echo ${row} | base64 --decode | jq -r ${1}; }
    current_config=$(echo ${row} | base64 --decode)
    reconcile_dispatch "$current_config"
done
detect_unmanaged_workloads
log "INFO" "Run complete."