#!/bin/bash
# Load environment variables from .env file
ENV_PATH="$(dirname "$0")/.env"

if [ -f "$ENV_PATH" ]; then
    source "$ENV_PATH"
else
    echo "Error: .env file not found at $ENV_PATH" >&2
    exit 1
fi

# ==============================================================================
# This will send notifications to a Telegram bot with the status of your NVMe SSD 
# and the integrity of your pgBackRest backups, deployed at SCPC Carmen Fleet Management
# server: trucking01
# ==============================================================================

# 1. Check NVMe SSD Health
SSD_HEALTH=$(sudo smartctl -H /dev/nvme0n1 | grep "test result" | awk '{print $NF}')
SSD_WEAR=$(sudo smartctl -A /dev/nvme0n1 | grep "Percentage Used" | awk '{print $NF}')

# 2. Verify Backup Integrity
# This forces pgBackRest to check every file in your backup against its original checksum
sudo -u postgres pgbackrest --stanza=my_prod_db verify > /dev/null 2>&1
if [ $? -eq 0 ]; then
    PG_VERIFY="OK"
else
    PG_VERIFY="FAILED"
fi

# 3. Send Telegram Report
MESSAGE="🗓️ Monthly Maintenance Report: $(hostname)
-------------------------------
🚀 SSD Status: $SSD_HEALTH
📉 SSD Wear: $SSD_WEAR
-------------------------------
✅ pgBackRest Integrity: $PG_VERIFY"

curl -s -X POST "https://api.telegram.org/bot$TOKEN//sendMessage" -d "chat_id=$CHAT_ID" -d "text=$MESSAGE"


