FROM mcr.microsoft.com/powershell:7.4-ubuntu-22.04

LABEL org.opencontainers.image.source="https://github.com/KrX3D/uup-dump-get-latest-windows-iso"
LABEL org.opencontainers.image.description="Downloads and creates Windows ISO files using UUP dump"
LABEL org.opencontainers.image.licenses="MIT"

RUN apt-get update && apt-get install -y --no-install-recommends \
    aria2 \
    wimtools \
    genisoimage \
    p7zip-full \
    cabextract \
    chntpw \
    curl \
    wget \
    bc \
    openssl \
    gosu \
    && rm -rf /var/lib/apt/lists/*

# Pre-cache UUP converter files to avoid git.uupdump.net failures at runtime.
# Uses the Gitea API to resolve the latest commit hash (immutable CDN URLs are more
# reliably cached by Cloudflare than branch HEAD URLs). Non-fatal: if git.uupdump.net
# is unreachable at build time, aria2 will attempt it at runtime instead.
RUN mkdir -p /opt/uup-converter && \
    hash=$(curl -sf --max-time 15 \
        "https://git.uupdump.net/api/v1/repos/uup-dump/converter/commits?limit=1&sha=master" \
        2>/dev/null | grep -o '"sha":"[0-9a-f]*"' | head -1 | cut -d'"' -f4) && \
    echo "UUP converter commit: ${hash:-not_found}" && \
    if [ -n "$hash" ]; then \
        for f in convert.sh convert_ve_plugin; do \
            curl -fL --max-time 120 --retry 5 --retry-delay 20 \
                "https://git.uupdump.net/uup-dump/converter/raw/commit/$hash/$f" \
                -o "/opt/uup-converter/$f" 2>/dev/null && \
            test -s "/opt/uup-converter/$f" && echo "Cached $f" || \
            echo "WARNING: Could not cache $f"; \
        done; \
        chmod +x /opt/uup-converter/convert.sh /opt/uup-converter/convert_ve_plugin 2>/dev/null; \
    else \
        echo "WARNING: Could not resolve converter commit hash"; \
    fi; \
    ls -la /opt/uup-converter/ || true

COPY entrypoint.sh /entrypoint.sh
COPY build-iso.ps1 /build-iso.ps1
RUN chmod +x /entrypoint.sh /build-iso.ps1

VOLUME ["/output", "/logs"]

ENV WINDOWS_TARGET="windows-11" \
    WINDOWS_RING="RETAIL" \
    LANGUAGE="de-de" \
    EDITION="Professional" \
    OUTPUT_DIR="/output" \
    WORK_DIR="/work" \
    LOG_DIR="/logs" \
    PUID="99" \
    PGID="100"

ENTRYPOINT ["/entrypoint.sh"]
