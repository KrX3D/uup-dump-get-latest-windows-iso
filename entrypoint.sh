#!/bin/bash
set -euo pipefail

PUID="${PUID:-99}"
PGID="${PGID:-100}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
WORK_DIR="${WORK_DIR:-/work}"
LOG_DIR="${LOG_DIR:-/logs}"

mkdir -p "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR"

if [ "$(id -u)" = "0" ]; then
    chown "$PUID:$PGID" "$OUTPUT_DIR" "$WORK_DIR" "$LOG_DIR" 2>/dev/null || true
    exec gosu "$PUID:$PGID" env HOME=/tmp \
        pwsh -NoProfile -NonInteractive -File /build-iso.ps1 \
        -OutputDirectory "$OUTPUT_DIR" \
        -WorkDirectory "$WORK_DIR" \
        -LogDirectory "$LOG_DIR" \
        -WindowsTarget "${WINDOWS_TARGET:-windows-11}" \
        -Ring "${WINDOWS_RING:-RETAIL}" \
        -Language "${LANGUAGE:-de-de}" \
        -Edition "${EDITION:-Professional}"
else
    exec env HOME=/tmp \
        pwsh -NoProfile -NonInteractive -File /build-iso.ps1 \
        -OutputDirectory "$OUTPUT_DIR" \
        -WorkDirectory "$WORK_DIR" \
        -LogDirectory "$LOG_DIR" \
        -WindowsTarget "${WINDOWS_TARGET:-windows-11}" \
        -Ring "${WINDOWS_RING:-RETAIL}" \
        -Language "${LANGUAGE:-de-de}" \
        -Edition "${EDITION:-Professional}"
fi
