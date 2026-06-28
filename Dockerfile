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

COPY entrypoint.sh /entrypoint.sh
COPY build-iso.ps1 /build-iso.ps1
RUN chmod +x /entrypoint.sh /build-iso.ps1

VOLUME ["/output"]

ENV WINDOWS_TARGET="windows-11" \
    LANGUAGE="de-de" \
    EDITION="Professional" \
    OUTPUT_DIR="/output" \
    LOG_DIR="/logs" \
    PUID="99" \
    PGID="100"

ENTRYPOINT ["/entrypoint.sh"]
