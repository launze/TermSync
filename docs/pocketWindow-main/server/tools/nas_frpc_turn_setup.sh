#!/usr/bin/env bash
set -euo pipefail

CONFIG="/vol1/1000/frpc-ha/frpc.ini"
BACKUP="${CONFIG}.bak.pocketwindow-turn-$(date +%Y%m%d-%H%M%S)"

cp "$CONFIG" "$BACKUP"

if ! grep -q '^\[pocketwindow-turn-tcp\]' "$CONFIG"; then
  cat >>"$CONFIG" <<'EOF'

[pocketwindow-turn-tcp]
type = tcp
local_ip = 192.168.31.77
local_port = 3478
remote_port = 16903

[pocketwindow-turn-udp]
type = udp
local_ip = 192.168.31.77
local_port = 3478
remote_port = 16903
EOF
fi

docker exec frpc-ha frpc verify -c /etc/frp/frpc.ini
docker restart frpc-ha >/dev/null
sleep 2
docker logs --tail 40 frpc-ha 2>&1
