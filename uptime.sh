#!/bin/bash
# 1. Load and automatically export environment variables from .env
ENV_PATH="$(dirname "$0")/.env"

if [ -f "$ENV_PATH" ]; then
    set -a        # Automatically export all sourced variables
    source "$ENV_PATH"
    set +a        # Turn off automatic export
else
    echo "Error: .env file not found at $ENV_PATH" >&2
    exit 1
fi

# 2. Validate that the required variables are set
: "${NOCOBASE_URL:?Set NOCOBASE_URL in .env or the environment}"
: "${NOCOBASE_TOKEN:?Set NOCOBASE_TOKEN in .env or the environment}"{NOCOBASE_TOKEN:?Set NOCOBASE_TOKEN in .env or the environment}"

# ==============================================================================
# Linux Uptime Report + NocoBase Push
# Usage: sudo ./uptime.sh [SERVER_NAME]
# ==============================================================================

# ---------- 1. Configuration ----------
HOSTNAME_FULL="${1:-$(hostname)}"
SERVER_NAME="${HOSTNAME_FULL%%.*}"       # default to hostname if not passed
YEAR=$(date +%Y)
OUTPUT_FILE="Linux_Server_Uptime_Report_${YEAR}.csv"

# NocoBase credentials — replace with your real values

# ---------- 2. Install tuptime if missing ----------
if ! command -v tuptime &> /dev/null; then
    echo "Installing tuptime..."
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y tuptime -qq
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release -q && yum install -y tuptime -q || dnf install -y tuptime -q
    fi
fi

# ---------- 3. Find earliest tuptime record ----------
FIRST_BOOT_EPOCH=$(tuptime -s 2>/dev/null | grep -iE "^System startups" | awk '{print $NF}')
if [ -z "$FIRST_BOOT_EPOCH" ] || [ "$FIRST_BOOT_EPOCH" = "0" ]; then
    echo "⚠️  tuptime has no data."
    FIRST_BOOT_EPOCH=0
fi
FIRST_BOOT_DATE=$(date -d "@$FIRST_BOOT_EPOCH" +%Y-%m-%d 2>/dev/null || echo "1970-01-01")
echo "=== tuptime first record: $FIRST_BOOT_DATE (epoch $FIRST_BOOT_EPOCH) ==="
echo ""

# ---------- 4. NocoBase push function ----------
push_to_nocobase() {
    local collection="$1"
    local payload="$2"
    curl -s -X POST "${NOCOBASE_URL}/api/${collection}:create" \
        -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "${payload}" \
        -o /dev/null -w "  → NocoBase push HTTP %{http_code}\n"
}

# ---------- 5. CSV header ----------
echo "Month,Uptime_%,Downtime_%,Reboots,Target_Downtime_Met,Notes" > "$OUTPUT_FILE"

# ---------- 6. Loop each month ----------
for MONTH in 01 02 03 04 05 06 07 08 09 10 11 12; do
    MONTH_START="${YEAR}-${MONTH}-01"
    if [ "$MONTH" = "12" ]; then
        NEXT_YEAR=$((YEAR + 1)); NEXT_MONTH="01"
    else
        NEXT_YEAR=$YEAR; NEXT_MONTH=$(printf "%02d" $((10#$MONTH + 1)))
    fi
    MONTH_END="${NEXT_YEAR}-${NEXT_MONTH}-01"

    START_EPOCH=$(date -d "$MONTH_START" +%s)
    END_EPOCH=$(date -d "$MONTH_END"   +%s)
    TOTAL_SECS=$((END_EPOCH - START_EPOCH))

    # Case: before monitoring started
    if [ "$FIRST_BOOT_EPOCH" -ne 0 ] && [ "$END_EPOCH" -le "$FIRST_BOOT_EPOCH" ]; then
        echo "${YEAR}-${MONTH},N/A,N/A,N/A,N/A,Before monitoring started" >> "$OUTPUT_FILE"
        continue
    fi

    # Query tuptime
    TUPTIME_OUT=$(tuptime -r "$MONTH_START" "$MONTH_END" 2>/dev/null)
    UPTIME_SECS=$(echo "$TUPTIME_OUT"   | grep -iE "System uptime:"   | awk -F'=' '{gsub(/[^0-9]/,"",$2); print $2}')
    DOWNTIME_SECS=$(echo "$TUPTIME_OUT" | grep -iE "System downtime:" | awk -F'=' '{gsub(/[^0-9]/,"",$2); print $2}')
    REBOOTS=$(echo "$TUPTIME_OUT" | grep -iE "System startups:" | awk '{print $3}')

    # Fallback: no reboot = 100% uptime
    if [ -z "$UPTIME_SECS" ]; then
        NOW_EPOCH=$(date +%s)
        if [ "$START_EPOCH" -gt "$NOW_EPOCH" ]; then
            echo "${YEAR}-${MONTH},N/A,N/A,N/A,N/A,Future month" >> "$OUTPUT_FILE"
        else
            UP_PCT="100.0000"; DOWN_PCT="0.0000"; REBOOTS=0
            echo "${YEAR}-${MONTH},${UP_PCT},${DOWN_PCT},${REBOOTS},YES,No reboot recorded" >> "$OUTPUT_FILE"
            # Push to NocoBase
            push_to_nocobase "kpi_server_uptime" "{
                \"month\": \"${YEAR}-${MONTH}\",
                \"server_name\": \"${SERVER_NAME}\",
                \"os_type\": \"Linux\",
                \"uptime_percent\": ${UP_PCT},
                \"downtime_percent\": ${DOWN_PCT},
                \"reboots\": ${REBOOTS},
                \"data_source\": \"tuptime\",
                \"notes\": \"No reboot recorded\"
            }"
        fi
        continue
    fi

    # Normal calculation
    UP_PCT=$(awk "BEGIN {printf \"%.4f\", ($UPTIME_SECS / $TOTAL_SECS) * 100}")
    DOWN_PCT=$(awk "BEGIN {printf \"%.4f\", ($DOWNTIME_SECS / $TOTAL_SECS) * 100}")
    TARGET_MET="YES"
    awk "BEGIN {exit !($DOWN_PCT > 1.0)}" && TARGET_MET="NO"

    echo "${YEAR}-${MONTH},${UP_PCT},${DOWN_PCT},${REBOOTS},${TARGET_MET}," >> "$OUTPUT_FILE"

    # Add this before push_csv_row_to_nocobase
    get_device_uuid() {
        local hostname="$1"
        # Replace 'name' with whatever field in devices holds the hostname
        local response=$(curl -s "${NOCOBASE_URL}/api/devices:list?filter={\"name\":\"${hostname}\"}&pageSize=1" \
            -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
        echo "$response" | jq -r '.data[0].id // empty'
    }
    
    local device_uuid=$(get_device_uuid "$SERVER_NAME")


    if [ -z "$device_uuid" ]; then
        echo "⚠️ Device not found: $SERVER_NAME - using hostname field only"   
        # Push to NocoBase
        push_to_nocobase "kpi_server_uptime" "{
            \"month\": \"${YEAR}-${MONTH}\",
            \"hostname\": \"${SERVER_NAME}\",
            \"os_type\": \"linux\",
            \"uptime_percent\": ${UP_PCT},
            \"downtime_percent\": ${DOWN_PCT},
            \"reboots\": ${REBOOTS},
            \"data_source\": \"tuptime\",
            \"notes\": \"\"
        }"
    else 
        echo "→ Found device UUID: $device_uuid"    
        # Push to NocoBase
        push_to_nocobase "kpi_server_uptime" "{
            \"month\": \"${YEAR}-${MONTH}\",
            \"server_name\": \"${device_uuid}\",
            \"os_type\": \"linux\",
            \"uptime_percent\": ${UP_PCT},
            \"downtime_percent\": ${DOWN_PCT},
            \"reboots\": ${REBOOTS},
            \"data_source\": \"tuptime\",
            \"notes\": \"\"
        }"
    fi
done

echo ""
echo "✅ Report Generated: $(pwd)/${OUTPUT_FILE}"
column -t -s ',' "$OUTPUT_FILE"
