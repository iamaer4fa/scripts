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
# test_lookup.sh — Diagnose why device lookup fails
# ==============================================================================

# ---------- Configuration ----------


TEST_HOSTNAME="${1:-smmi082504d}"

echo "============================================"
echo " Device Lookup Diagnostic"
echo " Hostname: $TEST_HOSTNAME"
echo " NocoBase: $NOCOBASE_URL"
echo "============================================"
echo ""

# ---------- Test 1: Can we reach the API at all? ----------
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

# ---------- Test 2: What fields does a device have? ----------
echo "--- Test 2: First device record fields ---"
FIRST_DEVICE=$(curl -s "${NOCOBASE_URL}/api/devices:list?pageSize=1" \
    -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
echo "$FIRST_DEVICE" | jq '.data[0]' 2>/dev/null || echo "❌ jq parse failed"
echo ""

# ---------- Test 3: Total device count ----------
echo "--- Test 3: Total devices in collection ---"
COUNT=$(echo "$FIRST_DEVICE" | jq -r '.meta.count // "unknown"')
echo "Count: $COUNT"
echo ""

# ---------- Test 4: Try common field names ----------
echo "--- Test 4: Search by common field names ---"
for FIELD in name hostname device_name title label hostName deviceName; do
    RESULT=$(curl -s -G "${NOCOBASE_URL}/api/devices:list" \
        -H "Authorization: Bearer ${NOCOBASE_TOKEN}" \
        --data-urlencode "filter={\"${FIELD}\":\"${TEST_HOSTNAME}\"}")
    MATCH=$(echo "$RESULT" | jq -r '.data | length' 2>/dev/null)
    if [ "$MATCH" = "1" ]; then
        UUID=$(echo "$RESULT" | jq -r '.data[0].id')
        echo "✅ Field '$FIELD' matches → UUID: $UUID"
        FOUND_FIELD="$FIELD"
        FOUND_UUID="$UUID"
    elif [ "$MATCH" = "0" ]; then
        echo "   Field '$FIELD' → no match"
    else
        echo "   Field '$FIELD' → error: $(echo "$RESULT" | jq -r '.errors[0].message' 2>/dev/null)"
    fi
done
echo ""

# ---------- Summary ----------
echo "============================================"
if [ -n "$FOUND_UUID" ]; then
    echo "✅ SUCCESS"
    echo "   Field to filter on: $FOUND_FIELD"
    echo "   UUID: $FOUND_UUID"
    echo ""
    echo "Use this lookup in your script:"
    echo "  filter={\"$FOUND_FIELD\":\"<hostname>\"}"
    echo "  → .data[0].id"
else
    echo "❌ Device NOT found under any common field name"
    echo ""
    echo "Possible causes:"
    echo "  1. The hostname '$TEST_HOSTNAME' is not stored exactly as-is"
    echo "     (check case, spaces, full FQDN vs short name)"
    echo "  2. The hostname is in a field NOT in the list above"
    echo "     (run Test 2 output and look manually)"
    echo "  3. The devices collection requires a filter other than"
    echo "     exact match (e.g., case-insensitive, contains)"
    echo "  4. The device exists but under a different name"
    echo "     (try: $(hostname), $(hostname | cut -d. -f1), FQDN)"
fi
echo "============================================"
