#!/usr/bin/env bash
# Publish the agent-installer boot artifacts (kernel/initrd/rootfs + .ipxe) over Range-capable
# HTTP on :8080, for an iPXE-booted SNO node to fetch at provision time.
#
# RUN ON THE BASTION. The node executes iPXE over its PUBLIC NIC before any VLAN exists, so the
# artifacts must be reachable on the bastion's PUBLIC IP. nginx is used because BMC/iPXE fetches
# need HTTP Range (206) — Python's http.server returns 200 for full file only and breaks iPXE.
#
# Usage: serve-boot-artifacts.sh <boot-artifacts-dir>   (default: cluster-assets/boot-artifacts)
set -euo pipefail

ART_DIR="${1:-cluster-assets/boot-artifacts}"
PORT="${PORT:-8080}"
WEBROOT="/opt/install/boot-artifacts"

if [[ ! -d "$ART_DIR" ]]; then
  echo "FATAL: boot-artifacts dir not found: $ART_DIR (run 'make pxe-files' first)" >&2
  exit 2
fi

echo "==> Installing nginx (idempotent)"
command -v nginx >/dev/null 2>&1 || sudo dnf install -y nginx

echo "==> Staging artifacts into $WEBROOT"
sudo mkdir -p "$WEBROOT"
# Copy contents via "/." (not a shell glob): the agent installer leaves boot-artifacts root-only
# (0700), so a "$ART_DIR"/* glob expands in the calling shell and finds nothing. cp runs as root.
sudo cp -rf "$ART_DIR/." "$WEBROOT"/
sudo chmod -R a+rX "$WEBROOT"

echo "==> Writing nginx server block on :$PORT (autoindex, Range honored by default)"
sudo tee /etc/nginx/conf.d/boot-artifacts.conf >/dev/null <<EOF
server {
    listen $PORT default_server;
    listen [::]:$PORT default_server;
    root $WEBROOT;
    autoindex on;
    # nginx serves byte-range requests (206) for static files automatically.
}
EOF

# SELinux: allow nginx to read the custom webroot and bind the non-standard port.
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
  echo "==> SELinux contexts for $WEBROOT and tcp/$PORT"
  sudo semanage fcontext -a -t httpd_sys_content_t "$WEBROOT(/.*)?" 2>/dev/null || true
  sudo restorecon -R "$WEBROOT"
  sudo semanage port -a -t http_port_t -p tcp "$PORT" 2>/dev/null \
    || sudo semanage port -m -t http_port_t -p tcp "$PORT" 2>/dev/null || true
fi

echo "==> Opening firewall tcp/$PORT (if firewalld is active)"
if sudo systemctl is-active --quiet firewalld; then
  sudo firewall-cmd --add-port="$PORT/tcp" --permanent >/dev/null
  sudo firewall-cmd --reload >/dev/null
fi

echo "==> Enabling + (re)starting nginx"
sudo nginx -t
sudo systemctl enable --now nginx
sudo systemctl reload nginx || sudo systemctl restart nginx

echo "==> Verifying HTTP Range (expect 206)"
sleep 1
A_FILE="$(basename "$(ls "$WEBROOT" | head -1)")"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1' "http://127.0.0.1:$PORT/$A_FILE" || true)"
if [[ "$CODE" == "206" ]]; then
  echo "OK: Range honored (206) for /$A_FILE"
else
  echo "WARN: expected 206 for Range request, got $CODE — iPXE fetch may fail" >&2
fi

echo
echo "Boot artifacts published. Feed Latitude this iPXE URL (over the bastion PUBLIC IP):"
echo "  http://<bastion_public_ipv4>:$PORT/agent.x86_64.ipxe"
ls -la "$WEBROOT"
