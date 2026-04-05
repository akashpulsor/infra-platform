#!/bin/bash
# ======================================================================
# Dalai LLAMA - Telecom Infra Installer
#
# Installs and configures on a single Ubuntu 22.04/24.04 host:
#   1. Kamailio
#   2. FreeSWITCH
#   3. RTPEngine
#   4. CoTURN
#
# Notes:
#   - MinIO is NOT installed here. It is expected inside Kubernetes.
#   - PBX-Core runs inside the backend chart in Kubernetes.
#   - AI service runs inside Kubernetes as ai-service.
#   - This script writes /etc/dalai-pbx-core.env as a reference/template for
#     the PBX-Core env values that should be provided through the backend chart.
#
# CHANGES from original (Kamailio 5.7 / Ubuntu 24.04 fixes):
#   - FLT_NATS define moved to top (before first use)
#   - tls.so loaded FIRST (before any module using libssl)
#   - usrloc.so loaded BEFORE registrar.so
#   - pv_auth_check replaced with consume_credentials (pv_auth_check not in 5.7)
#   - $sP replaced with $sp (lowercase in 5.7)
#   - http_client httpcon uses literal URL (not #!define ref inside quotes)
#   - listen=ws:/wss: replaced with listen=tcp:/tls: (5.7 handles WS via module)
#   - Kamailio WS port changed from 8080 to 8180 (avoids Istio envoy conflict)
#   - SHM_MEMORY/PKG_MEMORY uncommented in /etc/default/kamailio
# ======================================================================

# Run only the Kamailio config section
export PUBLIC_IP=204.168.186.235
export PBX_CORE_URL=https://api.dalaillama.in
export SIP_DOMAIN=sip.dalaillama.in
export ENABLE_KAMAILIO_TLS=true
export ENABLE_KAMAILIO_WSS=true
export KAMAILIO_TLS_CERT_FILE=/etc/letsencrypt/live/sip.dalaillama.in/fullchain.pem
export KAMAILIO_TLS_KEY_FILE=/etc/letsencrypt/live/sip.dalaillama.in/privkey.pem

# Then run just the Python config generator part from the script
set -euo pipefail

# -- Configuration (override with env vars) -----------------------------
PUBLIC_IP="${PUBLIC_IP:-$(curl -s4 ifconfig.me || echo YOUR_PUBLIC_IP)}"
PBX_CORE_URL="${PBX_CORE_URL:-https://api.dalaillama.in}"
SIP_DOMAIN="${SIP_DOMAIN:-sip.dalaillama.in}"
TURN_DOMAIN="${TURN_DOMAIN:-turn.dalaillama.in}"
TURN_SECRET="${TURN_SECRET:-changeme}"
ESL_PASSWORD="${ESL_PASSWORD:-ClueCon}"
ENABLE_KAMAILIO_TLS="${ENABLE_KAMAILIO_TLS:-true}"
ENABLE_KAMAILIO_WSS="${ENABLE_KAMAILIO_WSS:-true}"
ENABLE_TURN_TLS="${ENABLE_TURN_TLS:-true}"
INSTALL_CERTBOT="${INSTALL_CERTBOT:-true}"
OBTAIN_LETSENCRYPT_CERTS="${OBTAIN_LETSENCRYPT_CERTS:-false}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@dalaillama.in}"
SIP_TLS_DOMAIN="${SIP_TLS_DOMAIN:-${SIP_DOMAIN}}"
TURN_TLS_DOMAIN="${TURN_TLS_DOMAIN:-${TURN_DOMAIN}}"
KAMAILIO_TLS_CERT_FILE="${KAMAILIO_TLS_CERT_FILE:-/etc/letsencrypt/live/${SIP_TLS_DOMAIN}/fullchain.pem}"
KAMAILIO_TLS_KEY_FILE="${KAMAILIO_TLS_KEY_FILE:-/etc/letsencrypt/live/${SIP_TLS_DOMAIN}/privkey.pem}"
TURN_TLS_CERT_FILE="${TURN_TLS_CERT_FILE:-/etc/letsencrypt/live/${TURN_TLS_DOMAIN}/fullchain.pem}"
TURN_TLS_KEY_FILE="${TURN_TLS_KEY_FILE:-/etc/letsencrypt/live/${TURN_TLS_DOMAIN}/privkey.pem}"
FS_PREFIX="/usr/local/freeswitch"

echo "======================================================="
echo "  Dalai LLAMA Telecom Infra Installer"
echo "  Public IP:  ${PUBLIC_IP}"
echo "  PBX-Core:   ${PBX_CORE_URL}"
echo "  SIP Domain: ${SIP_DOMAIN}"
echo "  Kamailio TLS: ${ENABLE_KAMAILIO_TLS}"
echo "  Kamailio WSS: ${ENABLE_KAMAILIO_WSS}"
echo "  TURN TLS:     ${ENABLE_TURN_TLS}"
echo "======================================================="

if [ "${ENABLE_KAMAILIO_WSS}" = "true" ] && [ "${ENABLE_KAMAILIO_TLS}" != "true" ]; then
  echo "ERROR: ENABLE_KAMAILIO_WSS=true requires ENABLE_KAMAILIO_TLS=true"
  exit 1
fi

# ============================================================
# 1. SYSTEM UPDATE + BASE DEPENDENCIES
# ============================================================
echo "===== [1/8] Updating system + installing dependencies ====="
apt update && apt upgrade -y

apt install -y \
  git wget curl vim build-essential \
  pkg-config autoconf automake libtool cmake \
  libssl-dev libcurl4-openssl-dev libpcre3-dev libpcre2-dev \
  libspeex-dev libspeexdsp-dev libedit-dev \
  libsqlite3-dev libldns-dev libopus-dev \
  libpq-dev uuid-dev libsndfile1-dev \
  unixodbc-dev libavformat-dev libswscale-dev \
  liblua5.3-dev lua5.3 libjpeg-dev zlib1g-dev \
  libtiff-dev libspandsp-dev \
  nasm yasm \
  python3 python3-pip python3-venv \
  postgresql postgresql-contrib \
  ufw jq

apt install -y \
  kamailio \
  kamailio-json-modules \
  kamailio-websocket-modules \
  kamailio-tls-modules \
  kamailio-extra-modules \
  kamailio-utils-modules

apt install -y \
  rtpengine rtpengine-utils \
  coturn

if [ "${INSTALL_CERTBOT}" = "true" ]; then
  apt install -y certbot
fi

if [ "${OBTAIN_LETSENCRYPT_CERTS}" = "true" ]; then
  echo "===== [TLS] Obtaining Let's Encrypt certificates ====="
  certbot certonly --standalone --non-interactive --agree-tos \
    -m "${LETSENCRYPT_EMAIL}" \
    -d "${SIP_TLS_DOMAIN}"
  if [ "${TURN_TLS_DOMAIN}" != "${SIP_TLS_DOMAIN}" ]; then
    certbot certonly --standalone --non-interactive --agree-tos \
      -m "${LETSENCRYPT_EMAIL}" \
      -d "${TURN_TLS_DOMAIN}"
  fi
fi

if [ "${ENABLE_KAMAILIO_TLS}" = "true" ]; then
  if [ ! -f "${KAMAILIO_TLS_CERT_FILE}" ] || [ ! -f "${KAMAILIO_TLS_KEY_FILE}" ]; then
    echo "ERROR: Kamailio TLS enabled but cert/key not found:"
    echo "  cert: ${KAMAILIO_TLS_CERT_FILE}"
    echo "  key:  ${KAMAILIO_TLS_KEY_FILE}"
    echo "Set INSTALL_CERTBOT/OBTAIN_LETSENCRYPT_CERTS or provide files manually."
    exit 1
  fi
fi

if [ "${ENABLE_TURN_TLS}" = "true" ]; then
  if [ ! -f "${TURN_TLS_CERT_FILE}" ] || [ ! -f "${TURN_TLS_KEY_FILE}" ]; then
    echo "ERROR: TURN TLS enabled but cert/key not found:"
    echo "  cert: ${TURN_TLS_CERT_FILE}"
    echo "  key:  ${TURN_TLS_KEY_FILE}"
    echo "Set INSTALL_CERTBOT/OBTAIN_LETSENCRYPT_CERTS or provide files manually."
    exit 1
  fi
fi

# ============================================================
# 2. FIREWALL
# ============================================================
echo "===== [2/8] Configuring firewall ====="
ufw allow 22/tcp
ufw allow 5060/udp
ufw allow 5060/tcp
ufw allow 5061/tcp
ufw allow 7443/tcp
ufw allow 8180/tcp    # Changed from 8080 to avoid Istio envoy conflict
ufw allow 3478/udp
ufw allow 3478/tcp
ufw allow 5349/tcp
ufw allow 8021/tcp
ufw allow 30000:40000/udp
ufw allow 49152:65535/udp
ufw --force enable

# ============================================================
# 3. FREESWITCH
# ============================================================
echo "===== [3/8] Building FreeSWITCH from source ====="

cd /usr/src
if [ ! -d libks ]; then
  git clone https://github.com/signalwire/libks.git
fi
cd libks
cmake .
make -j"$(nproc)"
make install
ldconfig

cd /usr/local/src
if [ ! -d sofia-sip ]; then
  git clone https://github.com/freeswitch/sofia-sip.git
fi
cd sofia-sip
./bootstrap.sh -j
./configure
make -j"$(nproc)"
make install

cd /usr/local/src
if [ ! -d spandsp ]; then
  git clone https://github.com/freeswitch/spandsp.git
fi
cd spandsp
./bootstrap.sh -j
./configure
make -j"$(nproc)"
make install
ldconfig

cd /usr/local/src
if [ ! -d freeswitch ]; then
  git clone https://github.com/signalwire/freeswitch.git
fi
cd freeswitch
./bootstrap.sh

if ! grep -q "mod_audio_stream" modules.conf; then
  echo "applications/mod_audio_stream" >> modules.conf
fi

sed -i 's|^applications/mod_signalwire|#applications/mod_signalwire|g' modules.conf
sed -i 's|^applications/mod_av|#applications/mod_av|g' modules.conf

./configure
make -j"$(nproc)"
make install
make sounds-install
make moh-install

id -u freeswitch &>/dev/null || useradd -r -s /sbin/nologin freeswitch
chown -R freeswitch:freeswitch "${FS_PREFIX}"

# ============================================================
# 4. FREESWITCH CONFIGURATION
# ============================================================
echo "===== [4/8] Configuring FreeSWITCH ====="

cat > "${FS_PREFIX}/conf/autoload_configs/event_socket.conf.xml" << 'ESLEOF'
<configuration name="event_socket.conf" description="Socket Client">
  <settings>
    <param name="nat-map" value="false"/>
    <param name="listen-ip" value="0.0.0.0"/>
    <param name="listen-port" value="8021"/>
    <param name="password" value="ClueCon"/>
    <param name="apply-inbound-acl" value="any_v4.auto"/>
  </settings>
</configuration>
ESLEOF

sed -i "s|value=\"ClueCon\"|value=\"${ESL_PASSWORD}\"|g" "${FS_PREFIX}/conf/autoload_configs/event_socket.conf.xml"

cat > "${FS_PREFIX}/conf/autoload_configs/xml_curl.conf.xml" << XMLCURLEOF
<configuration name="xml_curl.conf" description="cURL XML Gateway">
  <bindings>
    <binding name="directory">
      <param name="gateway-url" value="${PBX_CORE_URL}/internal/freeswitch/directory"/>
      <param name="method" value="GET"/>
      <param name="timeout" value="5"/>
    </binding>
    <binding name="dialplan">
      <param name="gateway-url" value="${PBX_CORE_URL}/internal/freeswitch/dialplan"/>
      <param name="method" value="GET"/>
      <param name="timeout" value="5"/>
    </binding>
  </bindings>
</configuration>
XMLCURLEOF

if ! grep -q "mod_xml_curl" "${FS_PREFIX}/conf/autoload_configs/modules.conf.xml"; then
  sed -i '/<\/modules>/i\    <load module="mod_xml_curl"/>' "${FS_PREFIX}/conf/autoload_configs/modules.conf.xml"
fi

if ! grep -q "mod_audio_stream" "${FS_PREFIX}/conf/autoload_configs/modules.conf.xml"; then
  sed -i '/<\/modules>/i\    <load module="mod_audio_stream"/>' "${FS_PREFIX}/conf/autoload_configs/modules.conf.xml"
fi

cat > /etc/systemd/system/freeswitch.service << EOF
[Unit]
Description=FreeSWITCH - Dalai LLAMA Media Server
After=network.target

[Service]
Type=forking
User=freeswitch
Group=freeswitch
ExecStart=${FS_PREFIX}/bin/freeswitch -ncwait -nonat
ExecStop=${FS_PREFIX}/bin/fs_cli -x shutdown
Restart=always
RestartSec=5
LimitNOFILE=65536
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

mkdir -p /recordings
chown freeswitch:freeswitch /recordings

systemctl daemon-reload
systemctl enable freeswitch

# ============================================================
# 5. KAMAILIO CONFIGURATION
# ============================================================
echo "===== [5/8] Configuring Kamailio ====="


# TLS config file
if [ "${ENABLE_KAMAILIO_TLS}" = "true" ]; then
  mkdir -p /etc/kamailio/tls
  cat > /etc/kamailio/tls/tls.cfg << EOF
[server:default]
method = TLSv1.2+
verify_certificate = no
require_certificate = no
private_key = ${KAMAILIO_TLS_KEY_FILE}
certificate = ${KAMAILIO_TLS_CERT_FILE}
EOF
fi

# Fix /etc/default/kamailio - uncomment and set memory
sed -i 's/^#\?SHM_MEMORY=.*/SHM_MEMORY=256/' /etc/default/kamailio
sed -i 's/^#\?PKG_MEMORY=.*/PKG_MEMORY=16/' /etc/default/kamailio
sed -i 's/^#\?RUN_KAMAILIO=no/RUN_KAMAILIO=yes/' /etc/default/kamailio 2>/dev/null || true


# Validate config before enabling
echo "Validating Kamailio config..."
if kamailio -f /etc/kamailio/kamailio.cfg -c 2>&1 | grep -q "config file ok"; then
  echo "Kamailio config VALID"
else
  echo "WARNING: Kamailio config validation failed. Check /etc/kamailio/kamailio.cfg"
  kamailio -f /etc/kamailio/kamailio.cfg -c 2>&1
fi

systemctl enable kamailio

# ============================================================
# 6. RTPEngine
# ============================================================
echo "===== [6/8] Configuring RTPEngine ====="

cat > /etc/rtpengine/rtpengine.conf << EOF
[rtpengine]
interface=public/${PUBLIC_IP}
listen-ng=127.0.0.1:2223
port-min=30000
port-max=40000
log-level=6
log-facility=daemon
EOF

systemctl enable rtpengine
systemctl restart rtpengine

# ============================================================
# 7. CoTURN
# ============================================================
echo "===== [7/8] Configuring CoTURN ====="

cat > /etc/turnserver.conf << EOF
listening-port=3478
tls-listening-port=5349
external-ip=${PUBLIC_IP}
use-auth-secret
static-auth-secret=${TURN_SECRET}
realm=${TURN_DOMAIN}
log-file=/var/log/turnserver/turn.log
verbose
no-multicast-peers
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.168.0.0-192.168.255.255
total-quota=100
user-quota=10
max-bps=0
relay-threads=0
min-port=49152
max-port=65535
fingerprint
lt-cred-mech
no-cli
EOF

if [ "${ENABLE_TURN_TLS}" = "true" ]; then
  cat >> /etc/turnserver.conf << EOF
cert=${TURN_TLS_CERT_FILE}
pkey=${TURN_TLS_KEY_FILE}
EOF
else
  sed -i '/^tls-listening-port=/d' /etc/turnserver.conf
fi

mkdir -p /var/log/turnserver
chown turnserver:turnserver /var/log/turnserver 2>/dev/null || true
sed -i 's/^#TURNSERVER_ENABLED=1/TURNSERVER_ENABLED=1/' /etc/default/coturn 2>/dev/null || true
grep -q '^TURNSERVER_ENABLED=1$' /etc/default/coturn 2>/dev/null || echo 'TURNSERVER_ENABLED=1' >> /etc/default/coturn
systemctl enable coturn
systemctl restart coturn

# ============================================================
# 8. PBX-Core env template
# ============================================================
echo "===== [8/8] Writing PBX-Core telecom env template ====="

cat > /etc/dalai-pbx-core.env << EOF
# Apply these values through charts/backend-service/values-secret.yaml
# services.pbxCoreService.telecom.* and secrets.pbxCore.values.*
TELECOM_PUBLIC_IP=${PUBLIC_IP}
SIP_DOMAIN=${SIP_DOMAIN}
TURN_DOMAIN=${TURN_DOMAIN}
FREESWITCH_ESL_HOST=${PUBLIC_IP}
FREESWITCH_ESL_PORT=8021
FREESWITCH_ESL_PASSWORD=${ESL_PASSWORD}
COTURN_SECRET=${TURN_SECRET}
PBX_CORE_URL=${PBX_CORE_URL}
AI_SERVICE_URL=http://ai-service.apps.svc.cluster.local:8601
EOF
chmod 600 /etc/dalai-pbx-core.env

systemctl daemon-reload

echo ""
echo "===== Starting services ====="
systemctl start rtpengine
systemctl start coturn
systemctl start freeswitch
systemctl start kamailio

echo ""
echo "==================================================================="
echo "  INSTALLATION COMPLETE"
echo "==================================================================="
echo ""
echo "Services:"
echo "  Kamailio:    systemctl status kamailio"
echo "  FreeSWITCH:  systemctl status freeswitch"
echo "  RTPEngine:   systemctl status rtpengine"
echo "  CoTURN:      systemctl status coturn"
echo ""
echo "Generated reference files:"
echo "  /etc/dalai-pbx-core.env"
echo ""
echo "Next steps:"
echo "  1. Put /etc/dalai-pbx-core.env values into charts/backend-service/values-secret.yaml"
echo "  2. Enable and deploy pbx-core from charts/backend-service"
echo "  3. Enable and deploy ai-service from charts/backend-service"
echo "  4. TLS certs:"
echo "     Kamailio cert: ${KAMAILIO_TLS_CERT_FILE}"
echo "     Kamailio key:  ${KAMAILIO_TLS_KEY_FILE}"
echo "     TURN cert:     ${TURN_TLS_CERT_FILE}"
echo "     TURN key:      ${TURN_TLS_KEY_FILE}"
echo ""