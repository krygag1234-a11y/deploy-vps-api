#!/usr/bin/env bash
# Install a persistent SSH ControlMaster relay for short exec-API commands.
set -euo pipefail

NAME="${RELAY_NAME:-}"
TARGET="${RELAY_TARGET:-}"
KEY="${RELAY_KEY:-}"
INTERVAL="${RELAY_SERVER_ALIVE_INTERVAL:-30}"
COUNT="${RELAY_SERVER_ALIVE_COUNT_MAX:-3}"

usage() {
  cat <<'EOF'
Usage: install-ssh-relay.sh --name <alias> --target <user@host> --key <private-key>

Options:
  --name <alias>       SSH Host alias and systemd unit suffix, e.g. ru-olc
  --target <user@host> Remote SSH endpoint, e.g. root@203.0.113.10
  --key <path>         Existing private key on the API VPS
  --interval <sec>     ServerAliveInterval (default: 30)
  --count <n>          ServerAliveCountMax (default: 3)

The installer creates:
  /etc/ssh/ssh_config.d/90-olc-relay-<alias>.conf
  /etc/systemd/system/olc-relay-<alias>.service

Commands launched by exec API can then use: ssh <alias> '<command>'
They reuse the persistent ControlMaster socket instead of opening a new SSH
handshake for every request.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:-}"; shift 2 ;;
    --target) TARGET="${2:-}"; shift 2 ;;
    --key) KEY="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --count) COUNT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ $EUID -eq 0 ]] || { echo "Run as root" >&2; exit 1; }
[[ "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || { echo "Invalid --name" >&2; exit 2; }
[[ "$TARGET" =~ ^[a-zA-Z0-9._-]+@[a-zA-Z0-9:._-]+$ ]] || { echo "Invalid --target" >&2; exit 2; }
[[ "$KEY" == /* && -f "$KEY" ]] || { echo "--key must be an existing absolute file" >&2; exit 2; }
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --interval" >&2; exit 2; }
[[ "$COUNT" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid --count" >&2; exit 2; }
command -v ssh >/dev/null || { echo "openssh-client is required" >&2; exit 1; }

USER_NAME="${TARGET%@*}"
HOST_NAME="${TARGET#*@}"
CONFIG="/etc/ssh/ssh_config.d/90-olc-relay-${NAME}.conf"
UNIT="/etc/systemd/system/olc-relay-${NAME}.service"
CONTROL_DIR="/run/olc-ssh-relay"
BACKUP="/root/deploy-vps-api-backups/$(date -u +%Y%m%dT%H%M%SZ)-ssh-relay-${NAME}"

install -d -m 0700 "$BACKUP" "$CONTROL_DIR"
[[ -e "$CONFIG" ]] && cp -a "$CONFIG" "$BACKUP/"
[[ -e "$UNIT" ]] && cp -a "$UNIT" "$BACKUP/"

cat >"$CONFIG" <<EOF
Host $NAME
    HostName $HOST_NAME
    User $USER_NAME
    IdentityFile $KEY
    IdentitiesOnly yes
    BatchMode yes
    ConnectTimeout 15
    ConnectionAttempts 1
    ServerAliveInterval $INTERVAL
    ServerAliveCountMax $COUNT
    TCPKeepAlive yes
    Compression yes
    IPQoS none
    StrictHostKeyChecking accept-new
    UserKnownHostsFile /root/.ssh/known_hosts
    ControlMaster auto
    ControlPath $CONTROL_DIR/%C
    ControlPersist 30m
EOF
chmod 0600 "$CONFIG"

cat >"$UNIT" <<EOF
[Unit]
Description=Persistent SSH relay to $NAME
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
RuntimeDirectory=olc-ssh-relay
RuntimeDirectoryMode=0700
ExecStart=/usr/bin/ssh -NT -o ControlMaster=yes -o ControlPersist=no $NAME
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now "olc-relay-${NAME}.service"
relay_ready=0
for _ in $(seq 1 20); do
  if systemctl is-active --quiet "olc-relay-${NAME}.service" && ssh -O check "$NAME" >/dev/null 2>&1; then
    relay_ready=1
    break
  fi
  sleep 1
done
if [[ $relay_ready -ne 1 ]]; then
  systemctl status "olc-relay-${NAME}.service" --no-pager -l >&2 || true
  journalctl -u "olc-relay-${NAME}.service" -n 20 --no-pager >&2 || true
  echo "Relay did not become ready within 20 seconds" >&2
  exit 1
fi

echo "Relay is active: $NAME -> $TARGET"
echo "Control socket: $CONTROL_DIR/%C"
echo "Backup: $BACKUP"
echo "Test: ssh $NAME 'hostname'"
