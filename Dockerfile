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

# Bundle UUP converter files (MIT license, uup-dump/converter) to avoid
# runtime dependency on git.uupdump.net which is unreliable on some networks.
# Update converter-cache/ in this repo when UUP dump releases a new converter version.
COPY converter-cache/ /opt/uup-converter/
RUN chmod +x /opt/uup-converter/convert.sh /opt/uup-converter/convert_ve_plugin

COPY entrypoint.sh /entrypoint.sh
COPY build-iso.ps1 /build-iso.ps1
COPY web-ui.ps1    /web-ui.ps1
RUN chmod +x /entrypoint.sh /build-iso.ps1

VOLUME ["/output", "/logs", "/config"]

ENV WINDOWS_TARGET="windows-11" \
    WINDOWS_RING="RETAIL" \
    LANGUAGE="de-de" \
    EDITION="Professional" \
    OUTPUT_DIR="/output" \
    WORK_DIR="/work" \
    LOG_DIR="/logs" \
    PUID="99" \
    PGID="100" \
    MODE="auto" \
    WEB_PORT="8080"

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
