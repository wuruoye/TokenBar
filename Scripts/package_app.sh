#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="TokenBar"
APP_PATH="${TOKENBAR_APP_PATH:-$ROOT/$APP_NAME.app}"
RUST_TARGET_DIR="${TOKENBAR_RUST_TARGET_DIR:-$ROOT/.build/rust}"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE_IDENTIFIER="${TOKENBAR_BUNDLE_IDENTIFIER:-}"
BUNDLE_DISPLAY_NAME="${TOKENBAR_BUNDLE_DISPLAY_NAME:-}"

RUST_BUILD_FLAGS="${CARGO_ENCODED_RUSTFLAGS:-}"
for flag in \
  "--remap-path-prefix=$ROOT=/TokenBar" \
  "--remap-path-prefix=${HOME:-$ROOT}=/build-home"
do
  if [[ -n "$RUST_BUILD_FLAGS" ]]; then
    RUST_BUILD_FLAGS+=$'\x1f'
  fi
  RUST_BUILD_FLAGS+="$flag"
done

while [[ "$APP_PATH" != "/" && "$APP_PATH" == */ ]]; do
  APP_PATH="${APP_PATH%/}"
done
APP_BASENAME="$(basename "$APP_PATH")"
if [[ -z "$APP_PATH" || "$APP_BASENAME" != *.app || "$APP_BASENAME" == ".app" ]]; then
  echo "Refusing unsafe app output path: $APP_PATH" >&2
  exit 1
fi

APP_PARENT="$(dirname "$APP_PATH")"
mkdir -p "$APP_PARENT"
APP_PARENT="$(cd "$APP_PARENT" && pwd -P)"
APP_PATH="$APP_PARENT/$APP_BASENAME"
if [[ "$APP_PARENT" == "/" || "$APP_PATH" == "$ROOT" || "$APP_PATH" == "${HOME:-}" ]]; then
  echo "Refusing unsafe app output path: $APP_PATH" >&2
  exit 1
fi

validate_existing_app_target() {
  local target="$1"
  if [[ -L "$target" ]]; then
    echo "Refusing symlink app output path: $target" >&2
    return 1
  fi
  if [[ ! -e "$target" ]]; then
    return 0
  fi
  local plist="$target/Contents/Info.plist"
  local package_type=""
  if [[ -d "$target" && -f "$plist" ]]; then
    package_type="$(plutil -extract CFBundlePackageType raw -o - "$plist" 2>/dev/null || true)"
  fi
  if [[ "$package_type" != "APPL" ]]; then
    echo "Refusing to replace a path that is not an app bundle: $target" >&2
    return 1
  fi
}

validate_existing_app_target "$APP_PATH"

swift build --package-path "$ROOT" -c "$CONFIGURATION" --product TokenBar
SWIFT_BIN_DIR="$(swift build --package-path "$ROOT" -c "$CONFIGURATION" --show-bin-path)"

CARGO_ENCODED_RUSTFLAGS="$RUST_BUILD_FLAGS" cargo build \
  --manifest-path "$ROOT/Helper/Cargo.toml" \
  --target-dir "$RUST_TARGET_DIR" \
  --locked \
  --release \
  --bin tokenbar-helper

STAGING_ROOT="$(mktemp -d "$APP_PARENT/.tokenbar-package.XXXXXX")"
STAGING_PATH="$STAGING_ROOT/$APP_BASENAME"
cleanup() {
  if [[ -n "${STAGING_ROOT:-}" && -d "$STAGING_ROOT" && ! -L "$STAGING_ROOT" ]]; then
    rm -rf -- "$STAGING_ROOT"
  fi
}
trap cleanup EXIT

mkdir -p \
  "$STAGING_PATH/Contents/MacOS" \
  "$STAGING_PATH/Contents/Helpers" \
  "$STAGING_PATH/Contents/Resources"

cp "$ROOT/Resources/Info.plist" "$STAGING_PATH/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$STAGING_PATH/Contents/Resources/AppIcon.icns"
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
  if [[ -f "$ROOT/$notice" ]]; then
    cp "$ROOT/$notice" "$STAGING_PATH/Contents/Resources/$notice"
  fi
done
if [[ -f "$ROOT/Resources/ThirdPartyLicenses.html" ]]; then
  cp "$ROOT/Resources/ThirdPartyLicenses.html" "$STAGING_PATH/Contents/Resources/ThirdPartyLicenses.html"
fi
if [[ -n "$BUNDLE_IDENTIFIER" ]]; then
  plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$STAGING_PATH/Contents/Info.plist"
fi
if [[ -n "$BUNDLE_DISPLAY_NAME" ]]; then
  plutil -replace CFBundleDisplayName -string "$BUNDLE_DISPLAY_NAME" "$STAGING_PATH/Contents/Info.plist"
  plutil -replace CFBundleName -string "$BUNDLE_DISPLAY_NAME" "$STAGING_PATH/Contents/Info.plist"
fi
cp "$SWIFT_BIN_DIR/TokenBar" "$STAGING_PATH/Contents/MacOS/TokenBar"
cp "$RUST_TARGET_DIR/release/tokenbar-helper" "$STAGING_PATH/Contents/Helpers/tokenbar-helper"
chmod 755 \
  "$STAGING_PATH/Contents/MacOS/TokenBar" \
  "$STAGING_PATH/Contents/Helpers/tokenbar-helper"

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--timestamp --options runtime)
fi

codesign "${SIGN_ARGS[@]}" "$STAGING_PATH/Contents/Helpers/tokenbar-helper"
codesign "${SIGN_ARGS[@]}" "$STAGING_PATH/Contents/MacOS/TokenBar"
codesign "${SIGN_ARGS[@]}" "$STAGING_PATH"
codesign --verify --deep --strict "$STAGING_PATH"

validate_existing_app_target "$APP_PATH"
rm -rf -- "$APP_PATH"
mv "$STAGING_PATH" "$APP_PATH"
rmdir "$STAGING_ROOT"
echo "Created $APP_PATH"
