#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PROJECT_DIR=$(dirname -- "$SCRIPT_DIR")
REPO_ROOT=$(CDPATH= cd -- "$PROJECT_DIR/../.." && pwd)
OUTPUT=${1:-"$REPO_ROOT/.build/TokenBar-sync-linux.tar.gz"}
RUST_TARGET_DIR=${TOKENBAR_LINUX_RUST_TARGET_DIR:-"$REPO_ROOT/.build/linux-sync-rust"}
STAGING_ROOT=$(mktemp -d)
install -d -m 0755 "$(dirname -- "$OUTPUT")"

cleanup() {
    if [ -d "$STAGING_ROOT" ]; then
        rm -rf -- "$STAGING_ROOT"
    fi
}
trap cleanup EXIT

cargo build \
    --locked \
    --release \
    --manifest-path "$REPO_ROOT/Helper/Cargo.toml" \
    --target-dir "$RUST_TARGET_DIR" \
    --bin tokenbar-helper

install -d -m 0755 "$STAGING_ROOT/tokenbar-sync"
install -d -m 0755 "$STAGING_ROOT/tokenbar-sync/bin"
install -d -m 0755 "$STAGING_ROOT/tokenbar-sync/scripts"
install -d -m 0755 "$STAGING_ROOT/tokenbar-sync/systemd/user"
for executable in tokenbar-sync-client tokenbar-sync-server
do
    install -m 0755 "$PROJECT_DIR/bin/$executable" \
        "$STAGING_ROOT/tokenbar-sync/bin/$executable"
done
for script in install-server.sh install-user-client.sh package-linux.sh
do
    install -m 0755 "$PROJECT_DIR/scripts/$script" \
        "$STAGING_ROOT/tokenbar-sync/scripts/$script"
done
install -m 0644 "$PROJECT_DIR/systemd/server.env.example" \
    "$PROJECT_DIR/systemd/tokenbar-sync-server.service" \
    "$STAGING_ROOT/tokenbar-sync/systemd/"
install -m 0644 "$PROJECT_DIR/systemd/user/client.env.example" \
    "$PROJECT_DIR/systemd/user/tokenbar-sync-upload.service" \
    "$PROJECT_DIR/systemd/user/tokenbar-sync-upload.timer" \
    "$STAGING_ROOT/tokenbar-sync/systemd/user/"
install -d -m 0755 "$STAGING_ROOT/tokenbar-sync/tokenbar_sync"
for module in __init__.py client.py common.py server.py
do
    install -m 0644 "$PROJECT_DIR/tokenbar_sync/$module" \
        "$STAGING_ROOT/tokenbar-sync/tokenbar_sync/$module"
done
cp "$PROJECT_DIR/README.md" "$STAGING_ROOT/tokenbar-sync/"
cp "$REPO_ROOT/LICENSE" "$STAGING_ROOT/tokenbar-sync/"
cp "$REPO_ROOT/Sync/ThirdPartyLicenses.html" "$STAGING_ROOT/tokenbar-sync/"
install -m 0755 "$RUST_TARGET_DIR/release/tokenbar-helper" \
    "$STAGING_ROOT/tokenbar-sync/bin/tokenbar-helper"

tar -C "$STAGING_ROOT" -czf "$OUTPUT" tokenbar-sync
OUTPUT_DIR=$(dirname -- "$OUTPUT")
OUTPUT_NAME=$(basename -- "$OUTPUT")
(
    cd "$OUTPUT_DIR"
    sha256sum "$OUTPUT_NAME" >"$OUTPUT_NAME.sha256"
)
echo "Created $OUTPUT"
echo "Created $OUTPUT.sha256"
