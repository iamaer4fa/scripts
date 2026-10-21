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
: "${NOCOBASE_TOKEN:?Set NOCOBASE_TOKEN in .env or the environment}"
# ==============================================================================
# Linux Uptime Report + NocoBase Push
# - CSV is written first
# - NocoBase payload is built FROM the CSV row (single source of truth)
# Usage: sudo ./uptime.sh [SERVER_NAME]
# ==============================================================================
HOSTNAME_FULL="${1:-$(hostname)}"
SERVER_NAME="${HOSTNAME_FULL%%.*}"       # default to hostname if not passed

YEAR=$(date +%Y)
OUTPUT_FILE="Linux_Server_Uptime_Report_${YEAR}.csv"


# ---------- Install tuptime if missing ----------
if ! command -v tuptime &> /dev/null; then
    echo "Installing tuptime..."get_fallback_uptime_secs
    if [ -f /etc/debian_version ]; then
        apt-get update -qq && apt-get install -y tuptime -qq
    elif [ -f /etc/redhat-release ]; then
        yum install -y epel-release -q && yum install -y tuptime -q || dnf install -y tuptime -q
    fi
fi

# ---------- Find earliest tuptime record ----------
FIRST_BOOT_EPOCH=$(tuptime -s 2>/dev/null | grep -iE "^System startups" | awk '{print $NF}')
[ -z "$FIRST_BOOT_EPOCH" ] && FIRST_BOOT_EPOCH=0
FIRST_BOOT_DATE=$(date -d "@$FIRST_BOOT_EPOCH" +%Y-%m-%d 2>/dev/null || echo "1970-01-01")
echo "=== tuptime first record: $FIRST_BOOT_DATE (epoch $FIRST_BOOT_EPOCH) ==="
echo ""

# Query for device uuid
get_device_uuid() {
    local hostname="$1"
    local response
    response=$(curl -s -G "${NOCOBASE_URL}/api/devices:list" \
        -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
        --data-urlencode "filter={\"name\":{\"\$iLike\":\"${hostname}\"}}" \
        --data-urlencode "pageSize=1")
    echo "$response" | jq -r '.data[0].id // empty'
}
# ---------- Push a single CSV row to NocoBase ----------
# Reads the row's own Notes column and sends that exact string.
push_csv_row_to_nocobase() {
    local csv_row="$1"

    # Split CSV row into fields (comma-separated; Notes is last, may contain commas → take rest)
    local month   uptime downtime reboots target notes
    month=$(echo "$csv_row"   | cut -d',' -f1)
    uptime=$(echo "$csv_row"  | cut -d',' -f2)
    downtime=$(echo "$csv_row"| cut -d',' -f3)
    reboots=$(echo "$csv_row" | cut -d',' -f4)
    target=$(echo "$csv_row"  | cut -d',' -f5)
    notes=$(echo "$csv_row"   | cut -d',' -f6-)

    # Strip optional quotes from Notes
    notes=$(echo "$notes" | sed 's/^"//; s/"$//')

    # Convert N/A → null for numeric fields
    [ "$uptime"   = "N/A" ] && uptime=null
    [ "$downtime" = "N/A" ] && downtime=null
    [ "$reboots"  = "N/A" ] && reboots=null

    # kpi_met boolean
    local kpi_bool="false"
    [ "$target" = "YES" ] && kpi_bool="true"

    # data_source — inferred from notes
    local source="tuptime"
    case "$notes" in
        *"Before monitoring"*) source="none" ;;
        *"Future month"*)      source="none" ;;
        *"No reboot"*)         source="tuptime" ;;
    esac

    local device_uuid=$(get_device_uuid "$SERVER_NAME")


    if [ -z "$device_uuid" ]; then
        echo "Device not found: $SERVER_NAME - using hostname field only"    
        # Escape any double quotes inside notes
        notes=$(echo "$notes" | sed 's/"/\\"/g')
        local payload="{
            \"month\": \"${month}\",
            \"hostname\": \"${SERVER_NAME}\",
            \"os_type\": \"Linux\",
            \"uptime_percent\": ${uptime},
            \"downtime_percent\": ${downtime},
            \"reboots\": ${reboots},
            \"data_source\": \"${source}\",
            \"kpi_met\": ${kpi_bool},
            \"notes\": \"${notes}\"
        }"
    else 
        echo "→ Found device UUID: $device_uuid"    
        # Escape any double quotes inside notes
        notes=$(echo "$notes" | sed 's/"/\\"/g')
        local payload="{
            \"month\": \"${month}\",
            \"server_name\": \"${device_uuid}\",
            \"os_type\": \"Linux\",
            \"uptime_percent\": ${uptime},
            \"downtime_percent\": ${downtime},
            \"reboots\": ${reboots},
            \"data_source\": \"${source}\",
            \"kpi_met\": ${kpi_bool},
            \"notes\": \"${notes}\"
        }"
    fi

    curl -s -X POST "${NOCOBASE_URL}/api/kpi_server_uptime:create" \
        -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        -o /dev/null -w "  → [${month}] HTTP %{http_code} — notes=\"${notes}\"\n"
}

# ---------- CSV header ----------
echo "Month,Uptime_%,Downtime_%,Reboots,Target_Downtime_Met,Notes" > "$OUTPUT_FILE"

# ---------- Loop each month ----------
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

    # ---- Branch 0: before monitoring started ----
    if [ "$FIRST_BOOT_EPOCH" -ne 0 ] && [ "$END_EPOCH" -le "$FIRST_BOOT_EPOCH" ]; then
        ROW="${YEAR}-${MONTH},N/A,N/A,N/A,N/A,Before monitoring started"
        echo "$ROW" >> "$OUTPUT_FILE"
        push_csv_row_to_nocobase "$ROW"
        continue
    fi

    # ---- Query tuptime ----
    TUPTIME_OUT=$(tuptime -r "$MONTH_START" "$MONTH_END" 2>/dev/null)
    UPTIME_SECS=$(echo "$TUPTIME_OUT"   | grep -iE "System uptime:"   | awk -F'=' '{gsub(/[^0-9]/,"",$2); print $2}')
    DOWNTIME_SECS=$(echo "$TUPTIME_OUT" | grep -iE "System downtime:" | awk -F'=' '{gsub(/[^0-9]/,"",$2); print $2}')
    REBOOTS=$(echo "$TUPTIME_OUT" | grep -iE "System startups:" | awk '{print $3}')

    # ---- Branch 1: no tuptime data ----
    if [ -z "$UPTIME_SECS" ]; then
        NOW_EPOCH=$(date +%s)
        if [ "$START_EPOCH" -gt "$NOW_EPOCH" ]; then
            ROW="${YEAR}-${MONTH},N/A,N/A,N/A,N/A,Future month"
        else
            ROW="${YEAR}-${MONTH},100.0000,0.0000,0,YES,No reboot recorded"
        fi
        echo "$ROW" >> "$OUTPUT_FILE"
        push_csv_row_to_nocobase "$ROW"
        continue
    fi

    # ---- Branch 2: normal calculation ----
    TOTAL_SECS=$((END_EPOCH - START_EPOCH))
    UP_PCT=$(awk "BEGIN {printf \"%.4f\", ($UPTIME_SECS / $TOTAL_SECS) * 100}")
    DOWN_PCT=$(awk "BEGIN {printf \"%.4f\", ($DOWNTIME_SECS / $TOTAL_SECS) * 100}")
    TARGET_MET="YES"
    awk "BEGIN {exit !($DOWN_PCT > 1.0)}" && TARGET_MET="NO"

    NOTE="tuptime measured: uptime=${UPTIME_SECS}s, downtime=${DOWNTIME_SECS}s, reboots=${REBOOTS}"
    ROW="${YEAR}-${MONTH},${UP_PCT},${DOWN_PCT},${REBOOTS},${TARGET_MET},${NOTE}"
    echo "$ROW" >> "$OUTPUT_FILE"
    push_csv_row_to_nocobase "$ROW"
done

echo ""
echo "✅ Report Generated: $(pwd)/${OUTPUT_FILE}"
column -t -s ',' "$OUTPUT_FILE"
