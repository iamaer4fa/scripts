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
# Linux Uptime Report + NocoBase Push (CURRENT MONTH ONLY)
# - CSV is written first
# - NocoBase payload is built FROM the CSV row (single source of truth)
# ==============================================================================
HOSTNAME_FULL="${1:-$(hostname)}"
SERVER_NAME="${HOSTNAME_FULL%%.*}"       # default to hostname if not passed

# ---------- Reporting period: current month only ----------
MONTH_START=$(date +%Y-%m-01)
MONTH_KEY=$(date +%Y-%m)
NOW_ISO=$(date +%Y-%m-%dT%H:%M:%S)
OUTPUT_FILE="Linux_Server_Uptime_Report_${MONTH_KEY}.csv"


# ---------- Install tuptime if missing ----------
if ! command -v tuptime &> /dev/null; then
    echo "Installing tuptime..."
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
echo "=== Reporting period: $MONTH_START → $NOW_ISO (current month) ==="
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
        *"No tuptime data"*)   source="none" ;;
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

# ---------- Compute the current month's window ----------
START_EPOCH=$(date -d "$MONTH_START" +%s)
NOW_EPOCH=$(date +%s)
TOTAL_SECS=$((NOW_EPOCH - START_EPOCH))

# ---- Branch 0: before monitoring started ----
if [ "$FIRST_BOOT_EPOCH" -ne 0 ] && [ "$NOW_EPOCH" -le "$FIRST_BOOT_EPOCH" ]; then
    ROW="${MONTH_KEY},N/A,N/A,N/A,N/A,Before monitoring started"
    echo "$ROW" >> "$OUTPUT_FILE"
    push_csv_row_to_nocobase "$ROW"

# ---- Query tuptime for this month up to now ----
else
    TUPTIME_OUT=$(tuptime -r "$MONTH_START" "$NOW_ISO" 2>/dev/null)
    UPTIME_SECS=$(echo "$TUPTIME_OUT"   | grep -iE "System uptime:"   | awk -F'=' '{gsub(/[^0-9]/,"",$2); print $2}')
    DOWNTIME_SECS=$(echo "$TUPTIME_OUT" | grep -iE "System downtime:" | awk -F'=' '{gsub(/[^0-9]/,"",$2); print $2}')
    REBOOTS=$(echo "$TUPTIME_OUT" | grep -iE "System startups:" | awk '{print $3}')

    # ---- Branch 1: no tuptime data for this month yet ----
    if [ -z "$UPTIME_SECS" ] || [ "$TOTAL_SECS" -le 0 ]; then
        # Cannot claim measured uptime for a partial month with no data.
        ROW="${MONTH_KEY},N/A,N/A,N/A,N/A,No tuptime data for current month yet"
        echo "$ROW" >> "$OUTPUT_FILE"
        push_csv_row_to_nocobase "$ROW"

    # ---- Branch 2: normal calculation ----
    else
        UP_PCT=$(awk "BEGIN {printf \"%.4f\", ($UPTIME_SECS / $TOTAL_SECS) * 100}")
        DOWN_PCT=$(awk "BEGIN {printf \"%.4f\", ($DOWNTIME_SECS / $TOTAL_SECS) * 100}")
        TARGET_MET="YES"
        awk "BEGIN {exit !($DOWN_PCT > 1.0)}" && TARGET_MET="NO"

        NOTE="tuptime measured (partial month to ${NOW_ISO}): uptime=${UPTIME_SECS}s, downtime=${DOWNTIME_SECS}s, reboots=${REBOOTS}"
        ROW="${MONTH_KEY},${UP_PCT},${DOWN_PCT},${REBOOTS},${TARGET_MET},${NOTE}"
        echo "$ROW" >> "$OUTPUT_FILE"
        push_csv_row_to_nocobase "$ROW"
    fi
fi

echo ""
echo "✅ Report Generated: $(pwd)/${OUTPUT_FILE}"
column -t -s ',' "$OUTPUT_FILE"
