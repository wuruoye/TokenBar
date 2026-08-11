#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
REPO_ROOT=$(CDPATH= cd -- "$PROJECT_DIR/../.." && pwd)
USER_CONFIG_DIR=${XDG_CONFIG_HOME:-"$HOME/.config"}/tokenbar-sync
USER_UNIT_DIR=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user

HELPER_BINARY=${TOKENBAR_HELPER_BINARY:-}
if [ -z "$HELPER_BINARY" ]; then
    for candidate in \
        "$PROJECT_DIR/bin/tokenbar-helper" \
        "$REPO_ROOT/.build/rust/release/tokenbar-helper" \
        "$REPO_ROOT/Helper/target/release/tokenbar-helper"
    do
        if [ -x "$candidate" ]; then
            HELPER_BINARY=$candidate
            break
        fi
    done
fi
if [ -z "$HELPER_BINARY" ] || [ ! -x "$HELPER_BINARY" ]; then
    echo "tokenbar-helper binary not found" >&2
    echo "Build it with: cargo build --locked --release --manifest-path $REPO_ROOT/Helper/Cargo.toml" >&2
    echo "Or set TOKENBAR_HELPER_BINARY to a packaged Linux helper." >&2
    exit 1
fi

install -d -m 0700 "$HOME/.local/lib/tokenbar-sync/bin"
install -d -m 0700 "$HOME/.local/lib/tokenbar-sync/tokenbar_sync"
install -d -m 0700 "$USER_CONFIG_DIR"
install -d -m 0755 "$USER_UNIT_DIR"
install -m 0755 "$PROJECT_DIR/bin/tokenbar-sync-client" "$HOME/.local/lib/tokenbar-sync/bin/"
install -m 0755 "$HELPER_BINARY" "$HOME/.local/lib/tokenbar-sync/bin/tokenbar-helper"
install -m 0644 "$PROJECT_DIR/tokenbar_sync/__init__.py" "$HOME/.local/lib/tokenbar-sync/tokenbar_sync/"
install -m 0644 "$PROJECT_DIR/tokenbar_sync/common.py" "$HOME/.local/lib/tokenbar-sync/tokenbar_sync/"
install -m 0644 "$PROJECT_DIR/tokenbar_sync/client.py" "$HOME/.local/lib/tokenbar-sync/tokenbar_sync/"
install -m 0644 "$PROJECT_DIR/systemd/user/tokenbar-sync-upload.service" "$USER_UNIT_DIR/"
install -m 0644 "$PROJECT_DIR/systemd/user/tokenbar-sync-upload.timer" "$USER_UNIT_DIR/"

if [ ! -e "$USER_CONFIG_DIR/client.env" ]; then
    install -m 0600 "$PROJECT_DIR/systemd/user/client.env.example" "$USER_CONFIG_DIR/client.env"
fi

systemctl --user daemon-reload
echo "Installed but not enabled or started."
echo "Edit $USER_CONFIG_DIR/client.env, verify a manual upload, then explicitly run:"
echo "  systemctl --user enable --now tokenbar-sync-upload.timer"
