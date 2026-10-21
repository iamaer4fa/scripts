#!/bin/bash
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"
    set +a
fi

: "${NOCOBASE_URL:?Set NOCOBASE_URL in .env or the environment}"
: "${NOCOBASE_TOKEN:?Set NOCOBASE_TOKEN in .env or the environment}"

# ==============================================================================
# Simple test if UUID device found
# ==============================================================================

HOSTNAME_FULL="${1:-$(hostname)}"
SERVER_NAME="${HOSTNAME_FULL%%.*}"


get_device_uuid() {
    local hostname="$1"
    local response
    response=$(curl -s -G "${NOCOBASE_URL}/api/devices:list" \
        -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
        --data-urlencode "filter={\"name\":{\"\$iLike\":\"${hostname}\"}}" \
        --data-urlencode "pageSize=1")
    echo "$response" | jq -r '.data[0].id // empty'
}

device_uuid=$(get_device_uuid "$SERVER_NAME")

if [ -z "$device_uuid" ]; then
    echo "⚠️ Device not found: $SERVER_NAME - using hostname field only"
else
    echo "→ Found device $SERVER_NAME UUID: $device_uuid"
fi
