#!/usr/bin/env bash
# Publish the agent-installer boot artifacts (kernel/initrd/rootfs + .ipxe) over Range-capable
# HTTP for an iPXE-booted SNO node to fetch at provision time.
#
# RUN ON THE BASTION. The node executes iPXE over its PUBLIC NIC before any VLAN exists, so the
# endpoint must be reachable on the bastion's PUBLIC IP. nginx is used because BMC/iPXE fetches
# need HTTP Range (206) — Python's http.server returns 200 for full file only and breaks iPXE.
#
# SECURITY (issue #33): the agent initrd embeds the install ignition, which carries the
# install-config pullSecret (mirror creds) and sshKey. So this endpoint must NOT be a guessable,
# directory-listable public URL. This script therefore:
#   - serves ONLY under the exact path the generated .ipxe encodes (set via agent-config
#     bootArtifactsBaseURL = http://<bastion_pub>:8080/<UNGUESSABLE-TOKEN>) — pick a random token
#     so artifacts are not reachable at /agent.x86_64-initrd.img;
#   - disables directory listing (autoindex off) and server tokens;
#   - provides a `stop` mode to TEAR THE ENDPOINT DOWN once the node has booted (the window only
#     needs to be open during PXE).
#
# Usage:
#   serve-boot-artifacts.sh [serve] <boot-artifacts-dir>   # publish (default; dir from `make pxe-files`)
#   serve-boot-artifacts.sh stop                            # remove conf + webroot after boot
set -euo pipefail

MODE="serve"; case "${1:-}" in serve|stop) MODE="$1"; shift || true;; esac
ART_DIR="${1:-cluster-assets/boot-artifacts}"
PORT="${PORT:-8080}"
WEBROOT="/opt/install/boot-artifacts"
CONF="/etc/nginx/conf.d/boot-artifacts.conf"

if [[ "$MODE" == "stop" ]]; then
  echo "==> Closing the boot-artifact endpoint (removing conf + webroot)"
  sudo rm -f "$CONF"
  sudo rm -rf "$WEBROOT"
  if sudo nginx -t 2>/dev/null; then sudo systemctl reload nginx 2>/dev/null || sudo systemctl stop nginx; else sudo systemctl stop nginx; fi
  echo "Endpoint closed — the secret-bearing initrd is no longer served."
  exit 0
fi

if [[ ! -d "$ART_DIR" ]]; then
  echo "FATAL: boot-artifacts dir not found: $ART_DIR (run 'make pxe-files' first)" >&2
  exit 2
fi

# Derive the URL path the node will actually request from the generated .ipxe, and serve EXACTLY
# that. This guarantees the serve location matches the (tokenized) bootArtifactsBaseURL baked into
# the artifacts, and keeps the secret-bearing files off any guessable path. (Dir is 0700 root.)
IPXE="$ART_DIR/agent.x86_64.ipxe"
sudo test -f "$IPXE" || { echo "FATAL: $IPXE not found (run 'make pxe-files' first)" >&2; exit 2; }
URLPATH="$(sudo grep -oE 'http://[^/]+/[^ ]*agent\.x86_64-vmlinuz' "$IPXE" | head -1 | sed -E 's#https?://[^/]+##; s#/agent\.x86_64-vmlinuz$##')"
PREFIX="${URLPATH#/}"   # "" if bootArtifactsBaseURL had no path segment
if [[ -z "$PREFIX" ]]; then
  echo "WARN: the .ipxe base URL has NO path segment — artifacts would sit at a GUESSABLE root" >&2
  echo "      (e.g. /agent.x86_64-initrd.img, which leaks ignition secrets). Set agent-config" >&2
  echo "      bootArtifactsBaseURL to http://<bastion_pub>:$PORT/<random-token> and rebuild pxe-files." >&2
fi
DEST="$WEBROOT${URLPATH}"

echo "==> Installing nginx (idempotent)"
command -v nginx >/dev/null 2>&1 || sudo dnf install -y nginx

echo "==> Staging artifacts into $DEST"
sudo rm -rf "$WEBROOT"
sudo mkdir -p "$DEST"
# Copy contents via "/." (not a shell glob): the agent installer leaves boot-artifacts root-only
# (0700), so a "$ART_DIR"/* glob expands in the calling shell and finds nothing. cp runs as root.
sudo cp -rf "$ART_DIR/." "$DEST"/
sudo chmod -R a+rX "$WEBROOT"

echo "==> Writing nginx server block on :$PORT (listing OFF; only the tokenized path resolves)"
# IPv6 listen only when the host actually has IPv6, else `nginx -t` fails on a v6-disabled bastion.
V6_LISTEN=""
[[ -f /proc/net/if_inet6 ]] && V6_LISTEN="    listen [::]:$PORT default_server;"
sudo tee "$CONF" >/dev/null <<EOF
server {
    listen $PORT default_server;
$V6_LISTEN
    root $WEBROOT;
    autoindex off;          # no directory listing — do not advertise the secret-bearing initrd
    server_tokens off;
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

echo "==> Verifying HTTP Range (206) on the tokenized path AND that the root is NOT listable"
sleep 1
TOKURL="http://127.0.0.1:$PORT/${PREFIX:+$PREFIX/}agent.x86_64-initrd.img"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H 'Range: bytes=0-1' "$TOKURL" || true)"
[[ "$CODE" == "206" ]] && echo "OK: Range honored (206) on the tokenized path" \
                       || echo "WARN: expected 206 on the tokenized path, got $CODE — iPXE may fail" >&2
if [[ -n "$PREFIX" ]]; then
  ROOTCODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/agent.x86_64-initrd.img" || true)"
  [[ "$ROOTCODE" == "404" || "$ROOTCODE" == "403" ]] \
    && echo "OK: initrd NOT reachable at the guessable root (HTTP $ROOTCODE)" \
    || echo "WARN: initrd reachable without the token (HTTP $ROOTCODE) — check autoindex/path" >&2
fi

echo
echo "Boot artifacts published under the tokenized path. Feed Latitude this iPXE URL:"
echo "  http://<bastion_public_ipv4>:$PORT/${PREFIX:+$PREFIX/}agent.x86_64.ipxe"
echo "AFTER the node has booted, CLOSE the endpoint:  $0 stop"
