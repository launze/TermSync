set -e
cd /opt/termsync
ts=$(date +%Y%m%d%H%M%S)
if [ -x termsync-server ]; then
  cp -f termsync-server "deploy-backups/termsync-server.$ts"
fi
install -m 0755 "server-artifacts/termsync-server-v0.1.9" termsync-server
if [ -f /opt/download-portal/generate-download-portal.py ]; then
  python3 - <<'PY'
from pathlib import Path
path = Path("/opt/download-portal/generate-download-portal.py")
text = path.read_text(encoding="utf-8")
needle = '        ("Linux DEB", r"termsync-desktop-linux-x64-v(?P<version>\\d+(?:\\.\\d+)+)\\.deb$"),\n'
insert = needle + '        ("Linux arm64 AppImage", r"termsync-desktop-linux-arm64-v(?P<version>\\d+(?:\\.\\d+)+)\\.AppImage$"),\n        ("Linux arm64 DEB", r"termsync-desktop-linux-arm64-v(?P<version>\\d+(?:\\.\\d+)+)\\.deb$"),\n'
if "termsync-desktop-linux-arm64-v" not in text and needle in text:
    path.write_text(text.replace(needle, insert), encoding="utf-8")
PY
  python3 /opt/download-portal/generate-download-portal.py
fi
systemctl restart termsync.service
sleep 1
systemctl is-active --quiet termsync.service
if systemctl list-unit-files download-portal-8888.service >/dev/null 2>&1; then
  systemctl stop download-portal-8888.service || true
  old_pids=$(ss -ltnp 'sport = :8888' | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sort -u)
  for old_pid in $old_pids; do
    old_comm=$(ps -p "$old_pid" -o comm= 2>/dev/null || true)
    if [ "$old_comm" = "download-portal" ]; then
      kill "$old_pid" || true
    fi
  done
  sleep 1
  systemctl reset-failed download-portal-8888.service || true
  systemctl start download-portal-8888.service
elif systemctl list-unit-files download-portal.service >/dev/null 2>&1; then
  systemctl restart download-portal.service
fi
ls -lh /opt/termsync/server-artifacts/termsync-server*v0.1.9* /opt/termsync/downloads/*0.1.9* /opt/termsync/downloads/*latest* | tail -n 80