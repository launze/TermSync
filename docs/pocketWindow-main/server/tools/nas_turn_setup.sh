#!/usr/bin/env bash
set -euo pipefail

TURN_USER="${TURN_USER:-pocketwindow}"
TURN_PASS="${TURN_PASS:-pw-turn-2900-2026}"
TURN_REALM="${TURN_REALM:-pocketwindow}"
TURN_PORT="${TURN_PORT:-3478}"
MIN_PORT="${TURN_MIN_PORT:-16904}"
MAX_PORT="${TURN_MAX_PORT:-16905}"

echo "Installing coturn if needed..."
if ! command -v turnserver >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y coturn
fi

PUBLIC_IP="$(getent ahostsv4 ha.wwszxc.tax | awk '{print $1; exit}')"
LOCAL_IP="$(hostname -I | awk '{print $1}')"
if [ -z "${PUBLIC_IP}" ]; then
  PUBLIC_IP="ha.wwszxc.tax"
fi

cat >/etc/turnserver.conf <<EOF
listening-port=${TURN_PORT}
tls-listening-port=5349
listening-ip=0.0.0.0
relay-ip=${LOCAL_IP}
external-ip=${PUBLIC_IP}/${LOCAL_IP}
min-port=${MIN_PORT}
max-port=${MAX_PORT}
fingerprint
lt-cred-mech
user=${TURN_USER}:${TURN_PASS}
realm=${TURN_REALM}
server-name=${TURN_REALM}
no-cli
no-tls
no-dtls
no-multicast-peers
denied-peer-ip=0.0.0.0-0.255.255.255
denied-peer-ip=10.0.0.0-10.255.255.255
denied-peer-ip=100.64.0.0-100.127.255.255
denied-peer-ip=127.0.0.0-127.255.255.255
denied-peer-ip=169.254.0.0-169.254.255.255
denied-peer-ip=172.16.0.0-172.31.255.255
denied-peer-ip=192.0.2.0-192.0.2.255
denied-peer-ip=192.168.0.0-192.168.255.255
denied-peer-ip=198.18.0.0-198.19.255.255
denied-peer-ip=198.51.100.0-198.51.100.255
denied-peer-ip=203.0.113.0-203.0.113.255
EOF

if [ -f /etc/default/coturn ]; then
  sed -i 's/^#\?TURNSERVER_ENABLED=.*/TURNSERVER_ENABLED=1/' /etc/default/coturn
fi

systemctl enable coturn
systemctl restart coturn
systemctl --no-pager --full status coturn | sed -n '1,18p'
ss -lunpt | grep -E ":(${TURN_PORT}|5349)\b" || true

echo "TURN_URL=turn:ha.wwszxc.tax:16903?transport=tcp,turn:ha.wwszxc.tax:16903?transport=udp"
echo "TURN_USERNAME=${TURN_USER}"
echo "TURN_CREDENTIAL=${TURN_PASS}"
