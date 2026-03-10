# =============================================================
# Dalai LLAMA — FreeSWITCH with mod_audio_stream
# Base: Debian 12 (Bookworm) + FreeSWITCH 1.10 from source
# Includes: mod_audio_stream v1.0.3 for WebSocket audio streaming
# =============================================================

FROM debian:bookworm-slim AS builder

ENV DEBIAN_FRONTEND=noninteractive

# ── Build dependencies ──────────────────────────────────────
RUN apt-get update && apt-get -y install \
    git wget curl build-essential pkg-config cmake \
    uuid-dev zlib1g-dev libjpeg-dev libsqlite3-dev \
    libcurl4-openssl-dev libpcre3-dev libspeexdsp-dev \
    libldns-dev libedit-dev libtiff5-dev yasm libopus-dev \
    libsndfile1-dev unzip libavformat-dev libswscale-dev \
    libswresample-dev liblua5.2-dev liblua5.2-0 libpq-dev \
    unixodbc-dev autoconf automake ntpdate libxml2-dev \
    libpq5 libspeex-dev libtool libtool-bin libssl-dev \
    libevent-dev python3-dev flite1-dev libtiff-dev \
    && rm -rf /var/lib/apt/lists/*

# ── libks (SignalWire) ──────────────────────────────────────
RUN cd /usr/src \
    && git clone https://github.com/signalwire/libks.git \
    && cd libks \
    && cmake . -DCMAKE_INSTALL_PREFIX=/usr \
    && make -j$(nproc) \
    && make install

# ── signalwire-c ────────────────────────────────────────────
RUN cd /usr/src \
    && git clone https://github.com/signalwire/signalwire-c.git \
    && cd signalwire-c \
    && cmake . -DCMAKE_INSTALL_PREFIX=/usr \
    && make -j$(nproc) \
    && make install

# ── spandsp ─────────────────────────────────────────────────
RUN cd /usr/src \
    && git clone https://github.com/freeswitch/spandsp.git \
    && cd spandsp \
    && git checkout 0d2e6ac \
    && ./bootstrap.sh \
    && ./configure --prefix=/usr \
    && make -j$(nproc) \
    && make install

# ── sofia-sip ──────────────────────────────────────────────
RUN cd /usr/src \
    && git clone https://github.com/freeswitch/sofia-sip.git \
    && cd sofia-sip \
    && ./bootstrap.sh \
    && ./configure --prefix=/usr \
    && make -j$(nproc) \
    && make install

RUN ldconfig

# ── FreeSWITCH 1.10 from source ────────────────────────────
COPY modules.conf /tmp/modules.conf

RUN cd /usr/src \
    && git clone https://github.com/signalwire/freeswitch.git -b v1.10 \
    && cd freeswitch \
    && cp /tmp/modules.conf modules.conf \
    && ./bootstrap.sh -j \
    && ./configure --prefix=/usr/local/freeswitch \
    && make -j$(nproc) \
    && make install

# ── mod_audio_stream (pre-built Debian 12 package v1.0.3) ──
# Free for up to 10 concurrent streaming channels
RUN cd /usr/src \
    && wget -q https://github.com/amigniter/mod_audio_stream/releases/download/v1.0.3/mod-audio-stream_1.0.3_amd64.deb \
    && dpkg-deb -x mod-audio-stream_1.0.3_amd64.deb /usr/src/extracted/ \
    && mkdir -p /usr/local/freeswitch/mod \
    && find /usr/src/extracted -name "mod_audio_stream.so" -exec cp {} /usr/local/freeswitch/mod/ \;

# =============================================================
# Runtime stage — minimal image
# =============================================================
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get -y install --no-install-recommends \
    libsqlite3-0 libcurl4 libpcre3 libspeexdsp1 \
    libldns3 libedit2 libtiff6 libopus0 libsndfile1 \
    libavformat59 libswscale6 libswresample4 \
    liblua5.2-0 libpq5 unixodbc libssl3 libevent-2.1-7 \
    libxml2 libuuid1 libjpeg62-turbo zlib1g \
    ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Copy built libs
COPY --from=builder /usr/local/lib/ /usr/local/lib/
COPY --from=builder /usr/lib/libks* /usr/lib/
COPY --from=builder /usr/lib/libsignalwire* /usr/lib/
COPY --from=builder /usr/lib/libspandsp* /usr/lib/
COPY --from=builder /usr/lib/libsofia* /usr/lib/

# Copy FreeSWITCH
COPY --from=builder /usr/local/freeswitch/ /usr/local/freeswitch/

RUN ldconfig

# Symlinks for convenience
RUN ln -sf /usr/local/freeswitch/bin/freeswitch /usr/bin/freeswitch \
    && ln -sf /usr/local/freeswitch/bin/fs_cli /usr/bin/fs_cli

# Create freeswitch user
RUN groupadd freeswitch \
    && useradd --system --home /usr/local/freeswitch -g freeswitch freeswitch \
    && chown -R freeswitch:freeswitch /usr/local/freeswitch

# Config will be mounted from ConfigMap, but provide defaults if present
RUN if [ -d /usr/local/freeswitch/conf ]; then \
        cp -r /usr/local/freeswitch/conf /usr/local/freeswitch/conf.dist; \
    else \
        mkdir -p /usr/local/freeswitch/conf; \
    fi

# Volumes
VOLUME ["/usr/local/freeswitch/sounds", "/usr/local/freeswitch/recordings", "/usr/local/freeswitch/log"]

# Ports: SIP, ESL, SIP-TLS
EXPOSE 5080/udp 5080/tcp 5081/tcp 8021/tcp

# Health check
HEALTHCHECK --interval=15s --timeout=5s --retries=3 \
    CMD fs_cli -x "status" | grep -q "UP" || exit 1

ENTRYPOINT ["freeswitch"]
CMD ["-nonat", "-nf"]
