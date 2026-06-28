#!/bin/bash
set -euo pipefail

PUID="${PUID:-99}"
PGID="${PGID:-100}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
LOG_DIR="${LOG_DIR:-}"

mkdir -p "$OUTPUT_DIR"
if [ -n "$LOG_DIR" ]; then mkdir -p "$LOG_DIR"; fi

if [ "$(id -u)" = "0" ]; then
    chown "$PUID:$PGID" "$OUTPUT_DIR" 2>/dev/null || true
    if [ -n "$LOG_DIR" ]; then chown "$PUID:$PGID" "$LOG_DIR" 2>/dev/null || true; fi
    exec gosu "$PUID:$PGID" env HOME=/tmp \
        pwsh -NoProfile -NonInteractive -File /build-iso.ps1 \
        -OutputDirectory "$OUTPUT_DIR" \
        -LogDirectory "${LOG_DIR:-$OUTPUT_DIR}" \
        -WindowsTarget "${WINDOWS_TARGET:-windows-11}" \
        -Language "${LANGUAGE:-de-de}" \
        -Edition "${EDITION:-Professional}"
else
    exec env HOME=/tmp \
        pwsh -NoProfile -NonInteractive -File /build-iso.ps1 \
        -OutputDirectory "$OUTPUT_DIR" \
        -LogDirectory "${LOG_DIR:-$OUTPUT_DIR}" \
        -WindowsTarget "${WINDOWS_TARGET:-windows-11}" \
        -Language "${LANGUAGE:-de-de}" \
        -Edition "${EDITION:-Professional}"
fi
