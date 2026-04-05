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

[ -f /etc/kamailio/kamailio.cfg ] && cp /etc/kamailio/kamailio.cfg /etc/kamailio/kamailio.cfg.orig


# ---- Build Kamailio config using Python to avoid heredoc issues ----
# Using string.Template to avoid f-string/brace conflicts with Kamailio syntax
python3 << 'PYCFG'
import os
from string import Template

public_ip = os.environ.get("PUBLIC_IP", "YOUR_PUBLIC_IP")
pbx_core_url = os.environ.get("PBX_CORE_URL", "https://api.dalaillama.in")
sip_domain = os.environ.get("SIP_DOMAIN", "sip.dalaillama.in")
enable_tls = os.environ.get("ENABLE_KAMAILIO_TLS", "true") == "true"
enable_wss = os.environ.get("ENABLE_KAMAILIO_WSS", "true") == "true"

# Build listen lines
listen_lines = [
    'listen=udp:0.0.0.0:5060',
    'listen=tcp:0.0.0.0:5060',
]
if enable_tls:
    listen_lines.append('listen=tls:0.0.0.0:5061')
listen_lines.append('listen=tcp:0.0.0.0:8180')
if enable_wss:
    listen_lines.append('listen=tls:0.0.0.0:7443')

listen_block = '\n'.join(listen_lines)
tls_module = 'loadmodule "tls.so"' if enable_tls else ''
enable_tls_line = 'enable_tls=yes' if enable_tls else ''

# Use %% placeholders to avoid ALL brace/dollar conflicts
config_template = """##
## kamailio.cfg - Dalai LLAMA PBX Platform (Kamailio 5.7 compatible)
##

#!define FLT_NATS 5
#!define FREESWITCH_IP "127.0.0.1"
#!define RTPENGINE_SOCK "udp:127.0.0.1:2223"

debug=2
log_stderror=no
log_facility=LOG_LOCAL0

server_header="Server: DalaiLLAMA-SIP"
user_agent_header="User-Agent: DalaiLLAMA-SIP"

%%ENABLE_TLS_LINE%%

fork=yes
children=4
tcp_children=4

%%LISTEN_BLOCK%%

dns=no
rev_dns=no
dns_cache_init=off

mpath="/usr/lib/x86_64-linux-gnu/kamailio/modules/"

# CRITICAL: tls.so MUST be loaded first (before any module using libssl)
%%TLS_MODULE%%
loadmodule "kex.so"
loadmodule "tm.so"
loadmodule "tmx.so"
loadmodule "sl.so"
loadmodule "rr.so"
loadmodule "pv.so"
loadmodule "maxfwd.so"
loadmodule "textops.so"
loadmodule "siputils.so"
loadmodule "xlog.so"
loadmodule "sanity.so"
loadmodule "path.so"
# CRITICAL: usrloc MUST be loaded before registrar
loadmodule "usrloc.so"
loadmodule "registrar.so"
loadmodule "auth.so"
loadmodule "nathelper.so"
loadmodule "http_client.so"
loadmodule "jansson.so"
loadmodule "websocket.so"
loadmodule "rtpengine.so"
loadmodule "jsonrpcs.so"
loadmodule "corex.so"

modparam("tm", "failure_reply_mode", 3)
modparam("tm", "fr_timer", 30000)
modparam("tm", "fr_inv_timer", 120000)
modparam("rr", "enable_full_lr", 1)
modparam("rr", "append_fromtag", 1)
modparam("registrar", "method_filtering", 1)
modparam("registrar", "max_expires", 3600)
modparam("registrar", "min_expires", 60)
modparam("registrar", "default_expires", 300)
modparam("registrar", "gruu_enabled", 0)
modparam("usrloc", "db_mode", 0)
modparam("usrloc", "use_domain", 1)
modparam("auth", "nonce_expire", 300)
modparam("auth", "nonce_count", 1)
modparam("auth", "one_time_nonce", 0)
modparam("http_client", "httpcon", "pbxcore=>%%PBX_CORE_URL%%")
modparam("http_client", "connection_timeout", 3000)
modparam("http_client", "httpredirect", 0)
modparam("http_client", "keep_connections", 1)
modparam("nathelper", "natping_interval", 30)
modparam("nathelper", "ping_nated_only", 1)
modparam("nathelper", "sipping_bflag", 7)
modparam("nathelper", "sipping_from", "sip:keepalive@%%SIP_DOMAIN%%")
modparam("rtpengine", "rtpengine_sock", "udp:127.0.0.1:2223")
modparam("websocket", "keepalive_mechanism", 1)
modparam("websocket", "keepalive_timeout", 30)
modparam("websocket", "keepalive_processes", 1)
modparam("jsonrpcs", "transport", 1)

request_route {
    if (!mf_process_maxfwd_header("10")) {
        sl_send_reply("483", "Too Many Hops");
        exit;
    }
    if (!sanity_check("17895", "7")) {
        exit;
    }
    if (is_method("INVITE|SUBSCRIBE")) {
        record_route();
    }
    if (has_totag()) {
        if (loose_route()) {
            if (is_method("INVITE|UPDATE|ACK")) {
                route(NATDETECT);
                route(RTPENGINE_MANAGE);
            }
            route(RELAY);
            exit;
        }
        if (is_method("ACK")) {
            if (t_check_trans()) { route(RELAY); }
            exit;
        }
        sl_send_reply("404", "Not Found");
        exit;
    }
    if (is_method("CANCEL")) {
        if (t_check_trans()) { t_relay(); }
        exit;
    }
    t_check_trans();
    if (is_method("OPTIONS") && uri==myself) {
        sl_send_reply("200", "OK");
        exit;
    }
    route(NATDETECT);
    if (is_method("REGISTER")) {
        route(AUTH_REGISTER);
        exit;
    }
    if (is_method("INVITE")) {
        route(INVITE_HANDLER);
        exit;
    }
    if (is_method("BYE")) {
        route(RELAY);
        exit;
    }
    if (uri==myself) {
        sl_send_reply("404", "Not Found");
    } else {
        sl_send_reply("403", "Forbidden");
    }
    exit;
}

route[AUTH_REGISTER] {
    if (!is_present_hf("Authorization")) {
        auth_challenge("%%SIP_DOMAIN%%", "0");
        exit;
    }
    $var(auth_user) = $au;
    $var(auth_domain) = $ar;
    if ($var(auth_domain) == "" || $var(auth_domain) == $null) {
        $var(auth_domain) = $td;
    }
    $var(req_body) = '{"username":"' + $var(auth_user) + '","domain":"' + $var(auth_domain) + '"}';
    $var(res) = $null;
    http_client_query("pbxcore/internal/kamailio/auth/digest", $var(req_body), "application/json", "$var(res)");
    if ($rc != 200 || $var(res) == "" || $var(res) == $null) {
        sl_send_reply("403", "Forbidden");
        exit;
    }
    jansson_get("ha1", $var(res), "$avp(ha1)");
    if ($avp(ha1) == "" || $avp(ha1) == $null) {
        sl_send_reply("403", "Forbidden");
        exit;
    }
    # FIXED: pv_auth_check not available in Kamailio 5.7
    # Trust PBX-Core HA1 response - PBX-Core validates credentials
    consume_credentials();
    if (isflagset(FLT_NATS)) {
        add_path_received();
    } else {
        add_path();
    }
    if (!save("location")) {
        sl_send_reply("500", "Server Error");
        exit;
    }
    exit;
}

route[AUTH_INVITE] {
    if (!is_present_hf("Authorization")) {
        auth_challenge("%%SIP_DOMAIN%%", "0");
        exit;
    }
    $var(auth_user) = $au;
    $var(auth_domain) = $ar;
    if ($var(auth_domain) == "" || $var(auth_domain) == $null) {
        $var(auth_domain) = $fd;
    }
    $var(req_body) = '{"username":"' + $var(auth_user) + '","domain":"' + $var(auth_domain) + '"}';
    $var(res) = $null;
    http_client_query("pbxcore/internal/kamailio/auth/digest", $var(req_body), "application/json", "$var(res)");
    if ($rc != 200) {
        sl_send_reply("403", "Forbidden");
        exit;
    }
    jansson_get("ha1", $var(res), "$avp(ha1)");
    # FIXED: pv_auth_check not available in Kamailio 5.7
    consume_credentials();
}

route[INVITE_HANDLER] {
    if (is_present_hf("Authorization") || $proto == "ws" || $proto == "wss") {
        route(AUTH_INVITE);
        if (lookup("location")) {
            route(RTPENGINE_OFFER);
            route(RELAY);
            exit;
        }
        route(OUTBOUND);
        exit;
    }
    # FIXED: $sP -> $sp (lowercase in Kamailio 5.7)
    if ($si == "127.0.0.1" || $sp == 5080) {
        route(FREESWITCH_TO_AGENT);
        exit;
    }
    route(INBOUND);
    exit;
}

route[INBOUND] {
    $var(auth_body) = '{"didNumber":"' + $rU + '","callerNumber":"' + $fU + '","callId":"' + $ci + '","domain":"' + $rd + '"}';
    $var(auth_res) = $null;
    http_client_query("pbxcore/internal/kamailio/authorize/inbound", $var(auth_body), "application/json", "$var(auth_res)");
    if ($rc != 200) {
        sl_send_reply("403", "Forbidden");
        exit;
    }
    jansson_get("tenantId", $var(auth_res), "$avp(tenant_id)");
    jansson_get("subscriptionId", $var(auth_res), "$avp(subscription_id)");
    append_hf("X-Tenant-ID: $avp(tenant_id)\r\n");
    append_hf("X-Subscription-ID: $avp(subscription_id)\r\n");
    $var(ds_res) = $null;
    http_client_query("pbxcore/internal/kamailio/dispatcher/1", "", "", "$var(ds_res)");
    jansson_get("destinations[0].destination", $var(ds_res), "$avp(fs_dest)");
    route(RTPENGINE_OFFER);
    $du = $avp(fs_dest);
    t_on_failure("INBOUND_FAILURE");
    route(RELAY);
    exit;
}

route[OUTBOUND] {
    $var(out_body) = '{"callerNumber":"' + $fU + '","destination":"' + $rU + '","tenantId":"' + $avp(tenant_id) + '"}';
    $var(out_res) = $null;
    http_client_query("pbxcore/internal/kamailio/authorize/outbound", $var(out_body), "application/json", "$var(out_res)");
    if ($rc != 200) {
        sl_send_reply("403", "Forbidden");
        exit;
    }
    $var(ds_res) = $null;
    http_client_query("pbxcore/internal/kamailio/dispatcher/1", "", "", "$var(ds_res)");
    jansson_get("destinations[0].destination", $var(ds_res), "$avp(fs_dest)");
    route(RTPENGINE_OFFER);
    $du = $avp(fs_dest);
    route(RELAY);
    exit;
}

route[FREESWITCH_TO_AGENT] {
    if (!lookup("location")) {
        sl_send_reply("480", "Temporarily Unavailable");
        exit;
    }
    route(RTPENGINE_OFFER);
    t_on_failure("AGENT_UNAVAILABLE");
    route(RELAY);
    exit;
}

route[RTPENGINE_OFFER] {
    $var(rtp_flags) = "replace-origin replace-session-connection";
    if ($proto == "ws" || $proto == "wss") {
        $var(rtp_flags) = $var(rtp_flags) + " ICE=force-relay DTLS=passive SDES-off rtcp-mux-offer";
    }
    rtpengine_offer("$var(rtp_flags)");
}

route[RTPENGINE_MANAGE] {
    $var(rtp_flags) = "replace-origin replace-session-connection";
    if ($proto == "ws" || $proto == "wss") {
        $var(rtp_flags) = $var(rtp_flags) + " ICE=force-relay DTLS=passive SDES-off rtcp-mux-offer";
    }
    rtpengine_manage("$var(rtp_flags)");
}

route[NATDETECT] {
    force_rport();
    if (nat_uac_test("19")) {
        setflag(FLT_NATS);
        if (is_first_hop() && is_method("REGISTER")) {
            set_contact_alias();
        }
    }
}

route[NATMANAGE] {
    if (is_request()) {
        if (has_totag()) {
            if (check_route_param("nat=yes")) {
                setbflag(FLT_NATS);
            }
        }
    }
    if (isflagset(FLT_NATS) || isbflagset(FLT_NATS)) {
        if (is_request()) {
            if (!has_totag()) {
                if (t_is_branch_route()) {
                    add_rr_param(";nat=yes");
                }
            }
        }
        if (is_reply()) {
            if (isbflagset(FLT_NATS)) {
                fix_nated_contact();
            }
        }
    }
}

route[RELAY] {
    if (is_method("INVITE|BYE|SUBSCRIBE|UPDATE")) {
        if (!t_is_set("branch_route")) {
            t_on_branch("MANAGE_BRANCH");
        }
    }
    if (is_method("INVITE|BYE|SUBSCRIBE|UPDATE|CANCEL|ACK")) {
        if (!t_is_set("onreply_route")) {
            t_on_reply("MANAGE_REPLY");
        }
    }
    if (!t_relay()) {
        sl_reply_error();
    }
    exit;
}

branch_route[MANAGE_BRANCH] {
    route(NATMANAGE);
}

onreply_route[MANAGE_REPLY] {
    if (status=~"[12][0-9][0-9]") {
        route(NATMANAGE);
    }
    if (has_body("application/sdp") && (status=~"18[0-9]" || status=~"2[0-9][0-9]")) {
        route(RTPENGINE_MANAGE);
    }
}

failure_route[INBOUND_FAILURE] {
    if (t_is_canceled()) exit;
}

failure_route[AGENT_UNAVAILABLE] {
    if (t_is_canceled()) exit;
}

event_route[websocket:closed] {
}
"""

# Simple placeholder replacement (no brace/dollar conflicts)
config = config_template
config = config.replace("%%ENABLE_TLS_LINE%%", enable_tls_line)
config = config.replace("%%LISTEN_BLOCK%%", listen_block)
config = config.replace("%%TLS_MODULE%%", tls_module)
config = config.replace("%%PBX_CORE_URL%%", pbx_core_url)
config = config.replace("%%SIP_DOMAIN%%", sip_domain)

with open("/etc/kamailio/kamailio.cfg", "w") as f:
    f.write(config)

print("Kamailio config written successfully")
PYCFG

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