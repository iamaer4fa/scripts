#!/bin/bash

set -Eeuo pipefail

# ============================================================
# PostgreSQL Backup Script
# ============================================================

# PostgreSQL server
PGHOST="192.168.3.161"
PGPORT="5432"
PGUSER="postgres"

# Databases to back up
DATABASES=(
    "postgres"
    "atlas_cmms"
    "boxsmart"
    "itasset"
    "nocobase"
    "rollstock"
    "sales"
    "steniel_cmms"
    "steniel_networks"
    "stenielcmms"
    "trucking"
    "timetrex"
)

# Backup configuration
BACKUP_ROOT="/home/allanregistos/backup/postgresql"
RETENTION_DAYS=14

# ============================================================
# Functions
# ============================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error_exit() {
    log "ERROR: $*"
    exit 1
}

# ============================================================
# Initial checks
# ============================================================

if ! command -v pg_dump >/dev/null 2>&1; then
    error_exit "pg_dump is not installed or not in PATH."
fi

if ! command -v pg_restore >/dev/null 2>&1; then
    error_exit "pg_restore is not installed or not in PATH."
fi

if [ ! -f "$HOME/.pgpass" ]; then
    error_exit "$HOME/.pgpass does not exist."
fi

# PostgreSQL requires .pgpass to be protected
PGPASS_PERMS=$(stat -c "%a" "$HOME/.pgpass")

if [ "$PGPASS_PERMS" != "600" ]; then
    error_exit "$HOME/.pgpass must have permissions 600."
fi

# ============================================================
# Create timestamped backup directory
# ============================================================

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"

mkdir -p "$BACKUP_DIR"

log "============================================================"
log "PostgreSQL backup started"
log "Server: ${PGHOST}:${PGPORT}"
log "Backup directory: ${BACKUP_DIR}"
log "============================================================"

# ============================================================
# Test PostgreSQL connection
# ============================================================

if ! psql \
    -h "$PGHOST" \
    -p "$PGPORT" \
    -U "$PGUSER" \
    -d postgres \
    -c "SELECT 1;" \
    >/dev/null 2>&1; then

    rm -rf "$BACKUP_DIR"
    error_exit "Unable to connect to PostgreSQL."
fi

log "PostgreSQL connection successful."

# ============================================================
# Backup each database
# ============================================================

for DB in "${DATABASES[@]}"; do

    log "Starting backup of database: ${DB}"

    DUMP_FILE="${BACKUP_DIR}/${DB}.dump"

    # Create PostgreSQL custom-format dump
    if ! pg_dump \
        -h "$PGHOST" \
        -p "$PGPORT" \
        -U "$PGUSER" \
        -d "$DB" \
        --format=custom \
        --file="$DUMP_FILE" \
        --verbose; then

        log "ERROR: pg_dump failed for database ${DB}"
        rm -rf "$BACKUP_DIR"
        exit 1
    fi

    # Check that dump file exists and is not empty
    if [ ! -s "$DUMP_FILE" ]; then
        log "ERROR: Backup file is empty: ${DUMP_FILE}"
        rm -rf "$BACKUP_DIR"
        exit 1
    fi

    # Verify dump structure
    log "Verifying backup: ${DB}"

    if ! pg_restore \
        --list \
        "$DUMP_FILE" \
        >/dev/null; then

        log "ERROR: Backup verification failed for ${DB}"
        rm -rf "$BACKUP_DIR"
        exit 1
    fi

    SIZE=$(du -h "$DUMP_FILE" | cut -f1)

    log "Backup verified successfully: ${DB} (${SIZE})"

done

# ============================================================
# Save backup metadata
# ============================================================

{
    echo "Backup Date: $(date)"
    echo "PostgreSQL Host: ${PGHOST}"
    echo "PostgreSQL Port: ${PGPORT}"
    echo "PostgreSQL User: ${PGUSER}"
    echo "Backup Directory: ${BACKUP_DIR}"
    echo
    echo "Databases:"
    printf '%s\n' "${DATABASES[@]}"
} > "${BACKUP_DIR}/backup-info.txt"

# ============================================================
# Create compressed archive
# ============================================================

ARCHIVE="${BACKUP_ROOT}/postgresql_${TIMESTAMP}.tar.gz"

log "Creating compressed archive..."

tar -czf "$ARCHIVE" \
    -C "$BACKUP_ROOT" \
    "$TIMESTAMP"

if [ ! -s "$ARCHIVE" ]; then
    log "ERROR: Archive creation failed."
    rm -rf "$BACKUP_DIR"
    exit 1
fi

ARCHIVE_SIZE=$(du -h "$ARCHIVE" | cut -f1)

log "Archive created: ${ARCHIVE}"
log "Archive size: ${ARCHIVE_SIZE}"

# ============================================================
# Remove temporary directory
# ============================================================

rm -rf "$BACKUP_DIR"

# ============================================================
# Retention
# ============================================================

log "Removing backups older than ${RETENTION_DAYS} days..."

find "$BACKUP_ROOT" \
    -type f \
    -name 'postgresql_*.tar.gz' \
    -mtime +"$RETENTION_DAYS" \
    -delete

# ============================================================
# Final check
# ============================================================

if [ -f "$ARCHIVE" ]; then

    log "============================================================"
    log "BACKUP COMPLETED SUCCESSFULLY"
    log "File: ${ARCHIVE}"
    log "Size: ${ARCHIVE_SIZE}"
    log "============================================================"

else

    error_exit "Final backup file does not exist."
fi
