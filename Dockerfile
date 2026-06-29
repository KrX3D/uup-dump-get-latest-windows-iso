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
# Non-fatal: if git.uupdump.net is unreachable at build time, aria2 will attempt it at runtime.
RUN mkdir -p /opt/uup-converter && \
    for branch in main master; do \
        curl -fL --max-time 60 --retry 3 --retry-delay 15 \
            "https://git.uupdump.net/uup-dump/converter/raw/branch/${branch}/convert.sh" \
            -o /opt/uup-converter/convert.sh 2>/dev/null && \
        curl -fL --max-time 60 --retry 3 --retry-delay 15 \
            "https://git.uupdump.net/uup-dump/converter/raw/branch/${branch}/convert_ve_plugin" \
            -o /opt/uup-converter/convert_ve_plugin 2>/dev/null && \
        chmod +x /opt/uup-converter/convert.sh /opt/uup-converter/convert_ve_plugin && \
        echo "Cached UUP converter from branch: ${branch}" && break || \
        echo "Branch ${branch} not available, trying next..."; \
    done || true

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
