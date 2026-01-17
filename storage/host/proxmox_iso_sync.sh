#!/bin/bash
source /root/iac/common.lib
LOG_FILE="/var/log/proxmox_iso_sync.log"
MANIFEST="/root/iac/iso-images.json"
STORAGE_ID="local"

if ! command -v jq &> /dev/null; then log "ERROR" "jq missing."; exit 1; fi
if [ ! -f "$MANIFEST" ]; then log "ERROR" "Manifest missing."; exit 1; fi

STORAGE_PATH=$(safe_exec pvesm path "$STORAGE_ID:iso" 2>/dev/null | xargs dirname 2>/dev/null)
if [ -z "$STORAGE_PATH" ] || [ "$STORAGE_PATH" == "." ]; then STORAGE_PATH="/var/lib/vz/template/iso"; fi
if [ ! -d "$STORAGE_PATH" ]; then log "ERROR" "Path $STORAGE_PATH not found."; exit 1; fi

log "INFO" "Syncing ISOs to $STORAGE_PATH..."
declare -a KEPT_FILES=()
COUNT=$(jq '. | length' "$MANIFEST")

for ((i=0; i<$COUNT; i++)); do
    OS=$(jq -r ".[$i].os" "$MANIFEST")
    PAGE=$(jq -r ".[$i].source_page" "$MANIFEST")
    PATTERN=$(jq -r ".[$i].pattern" "$MANIFEST")
    VERSION=$(jq -r ".[$i].version // empty" "$MANIFEST")

    if [[ -n "$VERSION" ]]; then
        # v10.1 Variable Mode
        LATEST_FILE="${PATTERN//\$\{version\}/$VERSION}"
        if [[ "$PAGE" == *"github.com"* && "$PAGE" == *"download/" ]]; then DOWNLOAD_URL="${PAGE}${VERSION}/${LATEST_FILE}"; else DOWNLOAD_URL="${PAGE}${LATEST_FILE}"; fi
        log "CHECKING: $OS (Pinned: $VERSION)..."
    else
        # Dynamic Scraper Mode
        log "CHECKING: $OS (Scraping: $PATTERN)..."
        LATEST_FILE=$(curl -sL "$PAGE" | grep -oP "$PATTERN" | sort -V | tail -n 1)
        if [ -z "$LATEST_FILE" ]; then log "WARN" "Could not scrape file for $OS"; continue; fi
        if [[ "$PAGE" == */ ]]; then DOWNLOAD_URL="${PAGE}${LATEST_FILE}"; else DOWNLOAD_URL="${PAGE}/${LATEST_FILE}"; fi
    fi

    TARGET_FILE="$STORAGE_PATH/$LATEST_FILE"
    KEPT_FILES+=("$LATEST_FILE")
    if [ -f "$TARGET_FILE" ]; then
        log "OK: $LATEST_FILE exists."
    else
        log "NEW: $LATEST_FILE found."
        log "ACTION" "Downloading $DOWNLOAD_URL..."
        if safe_exec wget -q --show-progress -O "${TARGET_FILE}.tmp" "$DOWNLOAD_URL"; then
            mv "${TARGET_FILE}.tmp" "$TARGET_FILE"
            log "SUCCESS" "Downloaded $LATEST_FILE"
        else
            log "ERROR" "Download failed for $LATEST_FILE"
            rm -f "${TARGET_FILE}.tmp"
        fi
    fi
done

EXISTING_FILES=$(ls "$STORAGE_PATH"/*.iso "$STORAGE_PATH"/*.qcow2 "$STORAGE_PATH"/*.xz 2>/dev/null | xargs -n 1 basename)
for file in $EXISTING_FILES; do
    is_kept=false
    for kept in "${KEPT_FILES[@]}"; do if [[ "$file" == "$kept" ]]; then is_kept=true; break; fi; done
    if [ "$is_kept" == "false" ]; then log "DELETE" "Obsolete file: $file"; rm -f "$STORAGE_PATH/$file"; fi
done
