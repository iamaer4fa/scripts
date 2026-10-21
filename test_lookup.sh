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
# test_lookup.sh — Diagnose device lookup by hostname
# Usage: ./test_lookup.sh <hostname>
#   e.g. ./test_lookup.sh smmi082504d
# ==============================================================================

# ---------- Configuration ----------

# ---------- Hostname parameter ----------
TEST_HOSTNAME="$1"
if [ -z "$TEST_HOSTNAME" ]; then
    echo "Usage: $0 <hostname>"
    echo "Example: $0 smmi082504d"
    exit 1
fi

# Also derive the FQDN variant and short variant for testing
SHORT_NAME="${TEST_HOSTNAME%%.*}"
echo "============================================"
echo " Device Lookup Diagnostic"
echo " Hostname passed : $TEST_HOSTNAME"
echo " Short name      : $SHORT_NAME"
echo " NocoBase        : $NOCOBASE_URL"
echo "============================================"
echo ""

# ---------- Test 1: API reachability ----------
echo "--- Test 1: Basic API connectivity ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    "${NOCOBASE_URL}/api/devices:list?pageSize=1" \
    -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
echo "HTTP Status: $HTTP_CODE"
if [ "$HTTP_CODE" != "200" ]; then
    echo "❌ API unreachable. Check URL and token."
    exit 1
fi
echo "✅ API reachable."
echo ""

# ---------- Test 2: Field dump of first device ----------
echo "--- Test 2: First device record (all fields) ---"
FIRST_DEVICE=$(curl -s "${NOCOBASE_URL}/api/devices:list?pageSize=1" \
    -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
echo "$FIRST_DEVICE" | jq '.data[0]' 2>/dev/null || echo "❌ jq parse failed"
echo ""

# ---------- Test 3: Total count ----------
echo "--- Test 3: Total devices in collection ---"
COUNT=$(echo "$FIRST_DEVICE" | jq -r '.meta.count // "unknown"')
echo "Count: $COUNT"
echo ""

# ---------- Test 4: Try common field names ----------
# Try both the exact hostname AND the short name, case-insensitive
echo "--- Test 4: Search by common field names (case-insensitive) ---"

FOUND_FIELD=""
FOUND_UUID=""

for FIELD in name hostname device_name title label hostName deviceName computer_name server_name; do
    for VARIANT in "$TEST_HOSTNAME" "$SHORT_NAME"; do
        RESULT=$(curl -s -G "${NOCOBASE_URL}/api/devices:list" \
            -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
            --data-urlencode "filter={\"${FIELD}\":{\"\$iLike\":\"${VARIANT}\"}}")
        
        MATCH=$(echo "$RESULT" | jq -r '.data | length' 2>/dev/null)
        if [ "$MATCH" = "1" ]; then
            UUID=$(echo "$RESULT" | jq -r '.data[0].id')
            NAME_VAL=$(echo "$RESULT" | jq -r ".data[0].${FIELD}")
            echo "✅ Field '$FIELD' = '$NAME_VAL' matches variant '$VARIANT' → UUID: $UUID"
            if [ -z "$FOUND_UUID" ]; then
                FOUND_FIELD="$FIELD"
                FOUND_UUID="$UUID"
            fi
        elif [ "$MATCH" = "0" ]; then
            : # silent no-match (too verbose otherwise)
        else
            ERR=$(echo "$RESULT" | jq -r '.errors[0].message // "unknown error"' 2>/dev/null)
            echo "   Field '$FIELD' variant '$VARIANT' → error: $ERR"
        fi
    done
done
echo ""

# ---------- Test 5: Fuzzy contains match (last resort) ----------
if [ -z "$FOUND_UUID" ]; then
    echo "--- Test 5: Fuzzy contains match (partial hostname) ---"
    for FIELD in name hostname device_name title label; do
        RESULT=$(curl -s -G "${NOCOBASE_URL}/api/devices:list" \
            -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
            --data-urlencode "filter={\"${FIELD}\":{\"\$iLike\":\"%${SHORT_NAME}%\"}}")
        MATCH=$(echo "$RESULT" | jq -r '.data | length' 2>/dev/null)
        if [ "$MATCH" -gt "0" ] 2>/dev/null; then
            echo "Field '$FIELD' partial match count: $MATCH"
            echo "$RESULT" | jq -r '.data[] | "  → \(.id)  \((.'"$FIELD"') // "n/a")"'
        fi
    done
    echo ""
fi

# ---------- Summary ----------
echo "============================================"
if [ -n "$FOUND_UUID" ]; then
    echo "✅ SUCCESS"
    echo "   Filter field : $FOUND_FIELD"
    echo "   UUID         : $FOUND_UUID"
    echo ""
    echo "Use this in your script:"
    echo "  FIELD=\"$FOUND_FIELD\""
    echo "  filter={\"\$FIELD\":{\"\$iLike\":\"\${SHORT_NAME}\"}}"
else
    echo "❌ Device '$TEST_HOSTNAME' NOT found under any common field"
    echo ""
    echo "Next steps:"
    echo "  1. Look at Test 2 output above — identify which field contains"
    echo "     the device name/hostname."
    echo "  2. If the device is genuinely missing from 'devices', register it."
    echo "  3. If stored as FQDN, ensure your script sends the full FQDN."
    echo "  4. If case differs, use \$iLike (already used above)."
fi
echo "============================================"
