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
: "${ESXI_HOSTS[0]:?Set ESXI_HOSTS in .env using host|username|password entries}"

# ==============================================================================
# ESXi Uptime Report + NocoBase Push (CURRENT MONTH ONLY, esxcli-based)
# - Connects to each ESXi host over SSH
# - Runs: esxcli system stats uptime get  (returns MICROSECONDS)
# - Derives current-month uptime from the current boot duration
# - CSV is written first; NocoBase payload is built FROM the CSV row
# ==============================================================================

# ---------- ESXi hosts to report on ----------
# Format: "connect_address username password"
# connect_address can be an IP or FQDN — it is only used to SSH in.
# The real identity comes from `hostname` on the host itself.
# ---------- ESXi hosts to report on ----------
# Format: "hostname_or_ip username password"

IFS=';' read -r -a ESXI_HOSTS <<< "${ESXI_HOSTS:-}"
# ---------- Reporting period: current month only ----------
MONTH_START=$(date +%Y-%m-01)
MONTH_KEY=$(date +%Y-%m)
NOW_ISO=$(date +%Y-%m-%dT%H:%M:%S)
OUTPUT_FILE="ESXi_Uptime_Report_${MONTH_KEY}.csv"

# ---------- Compute current month window ----------
START_EPOCH=$(date -d "$MONTH_START" +%s)
NOW_EPOCH=$(date +%s)
TOTAL_SECS=$((NOW_EPOCH - START_EPOCH))

if [ "$TOTAL_SECS" -le 0 ]; then
    echo "ERROR: invalid reporting window ($MONTH_START → $NOW_ISO)." >&2
    exit 1
fi

# ---------- Query for device uuid ----------
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
# CSV columns: Month,Uptime_%,Downtime_%,Reboots,Target_Downtime_Met,Data_Source,Notes
push_csv_row_to_nocobase() {
    local csv_row="$1"
    local hostname="$2"

    local month uptime downtime reboots target source notes
    month=$(echo "$csv_row"    | cut -d',' -f1)
    uptime=$(echo "$csv_row"   | cut -d',' -f2)
    downtime=$(echo "$csv_row" | cut -d',' -f3)
    reboots=$(echo "$csv_row"  | cut -d',' -f4)
    target=$(echo "$csv_row"   | cut -d',' -f5)
    source=$(echo "$csv_row"   | cut -d',' -f6)
    notes=$(echo "$csv_row"    | cut -d',' -f7-)

    notes=$(echo "$notes" | sed 's/^"//; s/"$//')

    [ "$uptime"   = "N/A" ] && uptime=null
    [ "$downtime" = "N/A" ] && downtime=null
    [ "$reboots"  = "N/A" ] && reboots=null

    local kpi_bool="false"
    [ "$target" = "YES" ] && kpi_bool="true"

    local device_uuid
    device_uuid=$(get_device_uuid "$hostname")

    notes=$(echo "$notes" | sed 's/"/\\"/g')

    if [ -z "$device_uuid" ]; then
        echo "  Device not found: $hostname - using hostname field only"
        local payload="{
            \"month\": \"${month}\",
            \"hostname\": \"${hostname}\",
            \"os_type\": \"VMware ESXi\",
            \"uptime_percent\": ${uptime},
            \"downtime_percent\": ${downtime},
            \"reboots\": ${reboots},
            \"data_source\": \"${source}\",
            \"kpi_met\": ${kpi_bool},
            \"notes\": \"${notes}\"
        }"
    else
        echo "  → Found device UUID: $device_uuid"
        local payload="{
            \"month\": \"${month}\",
            \"server_name\": \"${device_uuid}\",
            \"os_type\": \"VMware ESXi\",
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
        -o /dev/null -w "  → [${month}] HTTP %{http_code} — host=${hostname} source=\"${source}\" notes=\"${notes}\"\n"
}

# ---------- CSV header ----------
echo "Month,Uptime_%,Downtime_%,Reboots,Target_Downtime_Met,Data_Source,Notes" > "$OUTPUT_FILE"

# ---------- Loop each ESXi host ----------
for HOST_ENTRY in "${ESXI_HOSTS[@]}"; do
    read -r ESXI_HOST ESXI_USER ESXI_PASS <<< "$HOST_ENTRY"

    echo ""
    echo "=== Connecting to $ESXI_HOST ==="

    SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10)

    # Resolve the real FQDN from the host itself
    ESXI_FQDN=$(sshpass -p "$ESXI_PASS" ssh "${SSH_OPTS[@]}" \
        "${ESXI_USER}@${ESXI_HOST}" "hostname" 2>/dev/null | tr -d '[:space:]')

    if [ -z "$ESXI_FQDN" ]; then
        echo "  ERROR: could not resolve hostname for $ESXI_HOST (SSH failed)" >&2
        ROW="${MONTH_KEY},N/A,N/A,N/A,N/A,none,SSH hostname lookup failed"
        echo "$ROW" >> "$OUTPUT_FILE"
        push_csv_row_to_nocobase "$ROW" "$ESXI_HOST"
        continue
    fi

    SERVER_NAME="${ESXI_FQDN%%.*}"
    echo "  Resolved hostname: $ESXI_FQDN (short: $SERVER_NAME)"

    # Query uptime in microseconds
    RAW_UPTIME=$(sshpass -p "$ESXI_PASS" ssh "${SSH_OPTS[@]}" \
        "${ESXI_USER}@${ESXI_HOST}" "esxcli system stats uptime get" 2>/dev/null \
        | tr -d '[:space:]')

    if ! [[ "$RAW_UPTIME" =~ ^[0-9]+$ ]]; then
        ROW="${MONTH_KEY},N/A,N/A,N/A,N/A,none,esxcli returned no valid uptime value"
        echo "$ROW" >> "$OUTPUT_FILE"
        push_csv_row_to_nocobase "$ROW" "$SERVER_NAME"
        continue
    fi

    HOST_UPTIME_SECS=$((RAW_UPTIME / 1000000))

    if [ "$HOST_UPTIME_SECS" -ge "$TOTAL_SECS" ]; then
        UP_SECS=$TOTAL_SECS
        REBOOTS=0
    else
        UP_SECS=$HOST_UPTIME_SECS
        REBOOTS=1
    fi

    DOWN_SECS=$((TOTAL_SECS - UP_SECS))
    [ "$DOWN_SECS" -lt 0 ] && DOWN_SECS=0

    UP_PCT=$(awk   "BEGIN {printf \"%.4f\", ($UP_SECS   / $TOTAL_SECS) * 100}")
    DOWN_PCT=$(awk "BEGIN {printf \"%.4f\", ($DOWN_SECS / $TOTAL_SECS) * 100}")

    TARGET_MET="YES"
    awk "BEGIN {exit !($DOWN_PCT > 1.0)}" && TARGET_MET="NO"

    NOTE="esxcli uptime (partial month to ${NOW_ISO}): host_uptime=${HOST_UPTIME_SECS}s, month_uptime=${UP_SECS}s, downtime_estimated=${DOWN_SECS}s"
    ROW="${MONTH_KEY},${UP_PCT},${DOWN_PCT},${REBOOTS},${TARGET_MET},esxcli,${NOTE}"
    echo "$ROW" >> "$OUTPUT_FILE"
    push_csv_row_to_nocobase "$ROW" "$SERVER_NAME"
done

echo ""
echo "✅ Report Generated: $(pwd)/${OUTPUT_FILE}"
column -t -s ',' "$OUTPUT_FILE"
