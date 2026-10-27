#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="TokenBar"
APP_PATH="${TOKENBAR_APP_PATH:-$ROOT/$APP_NAME.app}"
RUST_TARGET_DIR="${TOKENBAR_RUST_TARGET_DIR:-$ROOT/.build/rust}"
LOCAL_SIGNING_IDENTITY_FILE="$ROOT/.tokenbar-codesign-identity"
SIGNING_IDENTITY="${CODESIGN_IDENTITY:-}"
BUNDLE_IDENTIFIER="${TOKENBAR_BUNDLE_IDENTIFIER:-}"
BUNDLE_DISPLAY_NAME="${TOKENBAR_BUNDLE_DISPLAY_NAME:-}"
APP_GROUP="${TOKENBAR_APP_GROUP:-}"
WIDGET_NAME="TokenBarWidget"

if [[ -z "$SIGNING_IDENTITY" && (-e "$LOCAL_SIGNING_IDENTITY_FILE" || -L "$LOCAL_SIGNING_IDENTITY_FILE") ]]; then
  if [[ ! -f "$LOCAL_SIGNING_IDENTITY_FILE" || -L "$LOCAL_SIGNING_IDENTITY_FILE" ]]; then
    echo "Refusing unsafe local signing identity file: $LOCAL_SIGNING_IDENTITY_FILE" >&2
    exit 1
  fi
  SIGNING_IDENTITY="$(<"$LOCAL_SIGNING_IDENTITY_FILE")"
  if [[ -z "$SIGNING_IDENTITY" || "$SIGNING_IDENTITY" == *$'\n'* || "$SIGNING_IDENTITY" == *$'\r'* ]]; then
    echo "Local signing identity must contain exactly one non-empty line: $LOCAL_SIGNING_IDENTITY_FILE" >&2
    exit 1
  fi
fi
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"

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
swift build --package-path "$ROOT" -c "$CONFIGURATION" --product "$WIDGET_NAME"
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
RESOURCE_BUNDLE_PATH="$SWIFT_BIN_DIR/TokenBar_TokenBar.bundle"
if [[ ! -d "$RESOURCE_BUNDLE_PATH" ]]; then
  echo "Missing TokenBar resource bundle: $RESOURCE_BUNDLE_PATH" >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE_PATH" "$STAGING_PATH/Contents/Resources/"
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

# A WidgetKit extension must be sandboxed and share data with the app through
# an App Group. Without a provisioning profile, macOS only grants groups named
# after the signing team, so ad-hoc builds ship without the widget.
if [[ -z "$APP_GROUP" ]]; then
  TEAM_ID="$(codesign -dv "$STAGING_PATH/Contents/Helpers/tokenbar-helper" 2>&1 \
    | sed -n 's/^TeamIdentifier=//p')"
  if [[ -n "$TEAM_ID" && "$TEAM_ID" != "not set" ]]; then
    APP_GROUP="$TEAM_ID.$(plutil -extract CFBundleIdentifier raw -o - "$STAGING_PATH/Contents/Info.plist")"
  fi
fi
APP_SIGN_ARGS=("${SIGN_ARGS[@]}")
if [[ -n "$APP_GROUP" ]]; then
  APP_ENTITLEMENTS="$STAGING_ROOT/TokenBar.entitlements"
  WIDGET_ENTITLEMENTS="$STAGING_ROOT/$WIDGET_NAME.entitlements"
  plutil -create xml1 "$APP_ENTITLEMENTS"
  plutil -insert 'com\.apple\.security\.application-groups' -json "[\"$APP_GROUP\"]" "$APP_ENTITLEMENTS"
  cp "$APP_ENTITLEMENTS" "$WIDGET_ENTITLEMENTS"
  plutil -insert 'com\.apple\.security\.app-sandbox' -bool true "$WIDGET_ENTITLEMENTS"

  WIDGET_PATH="$STAGING_PATH/Contents/PlugIns/$WIDGET_NAME.appex"
  WIDGET_PLIST="$WIDGET_PATH/Contents/Info.plist"
  mkdir -p "$WIDGET_PATH/Contents/MacOS" "$WIDGET_PATH/Contents/Resources"
  cp "$ROOT/Resources/Widget-Info.plist" "$WIDGET_PLIST"
  for key in CFBundleShortVersionString CFBundleVersion; do
    plutil -replace "$key" -string \
      "$(plutil -extract "$key" raw -o - "$STAGING_PATH/Contents/Info.plist")" "$WIDGET_PLIST"
  done
  plutil -replace CFBundleIdentifier -string \
    "$(plutil -extract CFBundleIdentifier raw -o - "$STAGING_PATH/Contents/Info.plist").Widget" "$WIDGET_PLIST"
  for plist in "$STAGING_PATH/Contents/Info.plist" "$WIDGET_PLIST"; do
    plutil -replace TokenBarAppGroupIdentifier -string "$APP_GROUP" "$plist"
  done
  cp "$ROOT/Sources/TokenBar/Resources/ProviderIcon-codex.svg" \
    "$ROOT/Sources/TokenBar/Resources/ProviderIcon-claude.svg" \
    "$WIDGET_PATH/Contents/Resources/"
  cp "$SWIFT_BIN_DIR/$WIDGET_NAME" "$WIDGET_PATH/Contents/MacOS/$WIDGET_NAME"
  chmod 755 "$WIDGET_PATH/Contents/MacOS/$WIDGET_NAME"
  codesign "${SIGN_ARGS[@]}" --entitlements "$WIDGET_ENTITLEMENTS" "$WIDGET_PATH"
  APP_SIGN_ARGS+=(--entitlements "$APP_ENTITLEMENTS")
else
  echo "Skipping the desktop widget: it needs a signing identity with a team (see .tokenbar-codesign-identity)." >&2
fi

codesign "${APP_SIGN_ARGS[@]}" "$STAGING_PATH/Contents/MacOS/TokenBar"
codesign "${APP_SIGN_ARGS[@]}" "$STAGING_PATH"
codesign --verify --deep --strict "$STAGING_PATH"

validate_existing_app_target "$APP_PATH"
rm -rf -- "$APP_PATH"
mv "$STAGING_PATH" "$APP_PATH"
# A widget extension that is already running keeps the replaced binary until
# it exits; the system starts the new one for the next render.
pkill -f "$APP_PATH/Contents/PlugIns/$WIDGET_NAME.appex/Contents/MacOS/$WIDGET_NAME" 2>/dev/null || true
rm -f -- "$STAGING_ROOT"/*.entitlements
rmdir "$STAGING_ROOT"
echo "Created $APP_PATH"
