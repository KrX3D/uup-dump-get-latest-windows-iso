#!/bin/bash
set -euo pipefail

PUID="${PUID:-99}"
PGID="${PGID:-100}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
WORK_DIR="${WORK_DIR:-/work}"
LOG_DIR="${LOG_DIR:-/logs}"
MODE="${MODE:-auto}"
WEB_PORT="${WEB_PORT:-8080}"

mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR" /config

if [ "$(id -u)" = "0" ]; then
    chown "$PUID:$PGID" "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR" /config 2>/dev/null || true
    exec gosu "$PUID:$PGID" env HOME=/tmp \
        pwsh -NoProfile -NonInteractive -File /build-iso.ps1 \
        -OutputDirectory "$OUTPUT_DIR" \
        -WorkDirectory   "$WORK_DIR" \
        -LogDirectory    "$LOG_DIR" \
        -WindowsTarget   "${WINDOWS_TARGET:-windows-11}" \
        -Ring            "${WINDOWS_RING:-RETAIL}" \
        -Language        "${LANGUAGE:-de-de}" \
        -Edition         "${EDITION:-Professional}" \
        -Mode            "$MODE" \
        -WebPort         "$WEB_PORT"
else
    exec env HOME=/tmp \
        pwsh -NoProfile -NonInteractive -File /build-iso.ps1 \
        -OutputDirectory "$OUTPUT_DIR" \
        -WorkDirectory   "$WORK_DIR" \
        -LogDirectory    "$LOG_DIR" \
        -WindowsTarget   "${WINDOWS_TARGET:-windows-11}" \
        -Ring            "${WINDOWS_RING:-RETAIL}" \
        -Language        "${LANGUAGE:-de-de}" \
        -Edition         "${EDITION:-Professional}" \
        -Mode            "$MODE" \
        -WebPort         "$WEB_PORT"
fi
