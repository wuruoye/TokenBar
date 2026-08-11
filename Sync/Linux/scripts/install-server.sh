#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root" >&2
    exit 1
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")

if ! getent group tokenbar-sync >/dev/null 2>&1; then
    groupadd --system tokenbar-sync
fi
if ! id tokenbar-sync >/dev/null 2>&1; then
    useradd --system --gid tokenbar-sync --home-dir /var/lib/tokenbar-sync \
        --shell /usr/sbin/nologin tokenbar-sync
fi

install -d -o root -g root -m 0755 /opt/tokenbar-sync
install -d -o root -g root -m 0755 /opt/tokenbar-sync/bin
install -d -o root -g root -m 0755 /opt/tokenbar-sync/tokenbar_sync
install -d -o tokenbar-sync -g tokenbar-sync -m 0700 /var/lib/tokenbar-sync
install -d -o root -g tokenbar-sync -m 0750 /etc/tokenbar-sync

install -o root -g root -m 0755 "$PROJECT_DIR/bin/tokenbar-sync-server" /opt/tokenbar-sync/bin/
install -o root -g root -m 0644 "$PROJECT_DIR/tokenbar_sync/__init__.py" /opt/tokenbar-sync/tokenbar_sync/
install -o root -g root -m 0644 "$PROJECT_DIR/tokenbar_sync/common.py" /opt/tokenbar-sync/tokenbar_sync/
install -o root -g root -m 0644 "$PROJECT_DIR/tokenbar_sync/server.py" /opt/tokenbar-sync/tokenbar_sync/
install -o root -g root -m 0644 "$PROJECT_DIR/systemd/tokenbar-sync-server.service" /etc/systemd/system/

if [ ! -e /etc/tokenbar-sync/server.env ]; then
    install -o root -g tokenbar-sync -m 0640 "$PROJECT_DIR/systemd/server.env.example" /etc/tokenbar-sync/server.env
fi

systemctl daemon-reload
echo "Installed but not enabled or started."
echo "Edit /etc/tokenbar-sync/server.env, then explicitly run:"
echo "  systemctl enable --now tokenbar-sync-server.service"
