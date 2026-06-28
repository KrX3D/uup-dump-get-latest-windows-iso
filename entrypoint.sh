#!/bin/bash
set -euo pipefail

PUID="${PUID:-99}"
PGID="${PGID:-100}"
OUTPUT_DIR="${OUTPUT_DIR:-/output}"
WORK_DIR="${WORK_DIR:-}"

if [ -z "$WORK_DIR" ]; then
    WORK_DIR="$OUTPUT_DIR/.work"
fi

mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

if [ "$(id -u)" = "0" ]; then
    chown -R "$PUID:$PGID" "$OUTPUT_DIR" "$WORK_DIR" 2>/dev/null || true
    exec gosu "$PUID:$PGID" env HOME=/tmp \
        pwsh -NoProfile -NonInteractive -File /build-iso.ps1 \
        -OutputDirectory "$OUTPUT_DIR" \
        -WorkDirectory "$WORK_DIR" \
        -WindowsTarget "${WINDOWS_TARGET:-windows-11}" \
        -Language "${LANGUAGE:-de-de}" \
        -Edition "${EDITION:-Professional}"
else
    exec env HOME=/tmp \
        pwsh -NoProfile -NonInteractive -File /build-iso.ps1 \
        -OutputDirectory "$OUTPUT_DIR" \
        -WorkDirectory "$WORK_DIR" \
        -WindowsTarget "${WINDOWS_TARGET:-windows-11}" \
        -Language "${LANGUAGE:-de-de}" \
        -Edition "${EDITION:-Professional}"
fi
