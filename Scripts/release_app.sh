#!/usr/bin/env bash
set +x
set -euo pipefail

NOTARYTOOL_PROFILE_VALUE="${NOTARYTOOL_PROFILE:-}"
NOTARYTOOL_KEYCHAIN_PATH_VALUE="${NOTARYTOOL_KEYCHAIN_PATH:-}"
APPLE_API_KEY_PATH_VALUE="${APPLE_API_KEY_PATH:-}"
APPLE_API_KEY_ID_VALUE="${APPLE_API_KEY_ID:-}"
APPLE_API_ISSUER_ID_VALUE="${APPLE_API_ISSUER_ID:-}"
APPLE_ID_AUTH_REQUESTED=0
if [[ -n "${APPLE_ID:-}${APPLE_TEAM_ID:-}${APPLE_APP_PASSWORD:-}" ]]; then
  APPLE_ID_AUTH_REQUESTED=1
fi
unset NOTARYTOOL_PROFILE NOTARYTOOL_KEYCHAIN_PATH
unset APPLE_API_KEY_PATH APPLE_API_KEY_ID APPLE_API_ISSUER_ID
unset APPLE_ID APPLE_TEAM_ID APPLE_APP_PASSWORD

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="TokenBar"
SWIFT_PRODUCT="TokenBar"
RUST_PRODUCT="tokenbar-helper"
RUST_MANIFEST="$ROOT/Helper/Cargo.toml"
INFO_PLIST="$ROOT/Resources/Info.plist"
ICON="$ROOT/Resources/AppIcon.icns"
THIRD_PARTY_LICENSES="$ROOT/Resources/ThirdPartyLicenses.html"

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

DRY_RUN="${TOKENBAR_DRY_RUN:-0}"
BUILD_ONLY="${BUILD_ONLY:-0}"
NOTARIZE="${NOTARIZE:-1}"

usage() {
  cat <<'EOF'
Usage: Scripts/release_app.sh [--dry-run]

Creates a Universal 2 TokenBar.app, signs it, optionally notarizes and staples
it, then emits a zip and SHA-256 checksum. No sibling repository is required.

Formal release (default; required):
  CODESIGN_IDENTITY   Exact "Developer ID Application: ..." identity.
  One notary authentication mode:
    NOTARYTOOL_PROFILE
      Keychain profile created by `xcrun notarytool store-credentials`.
    APPLE_API_KEY_PATH + APPLE_API_KEY_ID [+ APPLE_API_ISSUER_ID]
      API key file must live outside this repository. Issuer is required for
      Team API keys and omitted for Individual API keys.

Optional:
  NOTARYTOOL_KEYCHAIN_PATH  Explicit keychain for a profile.
  NOTARYTOOL_TIMEOUT        notarytool --wait timeout (default: 30m).
  TOKENBAR_VERSION          CFBundleShortVersionString override.
  TOKENBAR_BUILD_NUMBER     CFBundleVersion override.
  TOKENBAR_BUNDLE_IDENTIFIER Bundle identifier override.
  TOKENBAR_RELEASE_DIR      Artifact directory.
  TOKENBAR_DRY_RUN=1        Validate configuration and print the plan only.

Local Universal 2 verification (not directly distributable):
  BUILD_ONLY=1 Scripts/release_app.sh
  # Equivalent: NOTARIZE=0 Scripts/release_app.sh

Build-only mode defaults to ad-hoc signing and skips Apple submission/stapling.
Gatekeeper may require users to right-click Open; never publish it as a release.
EOF
}

die() {
  echo "release_app.sh: $*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_boolean() {
  [[ "$2" == "0" || "$2" == "1" ]] || die "$1 must be 0 or 1"
}

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=1
  shift
elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi
[[ $# -eq 0 ]] || die "unknown argument: $1 (use --help)"

validate_boolean TOKENBAR_DRY_RUN "$DRY_RUN"
validate_boolean BUILD_ONLY "$BUILD_ONLY"
validate_boolean NOTARIZE "$NOTARIZE"
if [[ "$BUILD_ONLY" == "1" ]]; then
  NOTARIZE=0
fi

for command_name in swift cargo rustc lipo codesign ditto plutil shasum xcrun xattr find; do
  require_command "$command_name"
done
[[ -f "$RUST_MANIFEST" ]] || die "missing Rust manifest: $RUST_MANIFEST"
[[ -f "$INFO_PLIST" ]] || die "missing Info.plist: $INFO_PLIST"
[[ -f "$ICON" ]] || die "missing app icon: $ICON"
[[ -f "$THIRD_PARTY_LICENSES" ]] || die \
  "missing $THIRD_PARTY_LICENSES; run Scripts/generate_licenses.sh before packaging"

DEFAULT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$INFO_PLIST")"
DEFAULT_BUILD_NUMBER="$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")"
DEFAULT_BUNDLE_IDENTIFIER="$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")"
VERSION="${TOKENBAR_VERSION:-$DEFAULT_VERSION}"
BUILD_NUMBER="${TOKENBAR_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
BUNDLE_IDENTIFIER="${TOKENBAR_BUNDLE_IDENTIFIER:-$DEFAULT_BUNDLE_IDENTIFIER}"
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "unsafe TOKENBAR_VERSION: $VERSION"
[[ "$BUILD_NUMBER" =~ ^[0-9A-Za-z][0-9A-Za-z._-]*$ ]] || die "unsafe TOKENBAR_BUILD_NUMBER"
[[ -n "$BUNDLE_IDENTIFIER" && "$BUNDLE_IDENTIFIER" != *[[:space:]]* ]] || die "invalid bundle identifier"

MODE_SUFFIX=""
if [[ "$NOTARIZE" == "0" ]]; then
  MODE_SUFFIX="-build-only"
fi
RELEASE_DIR="${TOKENBAR_RELEASE_DIR:-$ROOT/dist/$APP_NAME-$VERSION$MODE_SUFFIX}"
if [[ "$RELEASE_DIR" != /* ]]; then
  RELEASE_DIR="$ROOT/$RELEASE_DIR"
fi
[[ "$RELEASE_DIR" != "/" && "$RELEASE_DIR" != "$ROOT" && "$RELEASE_DIR" != "${HOME:-}" ]] || \
  die "unsafe release directory: $RELEASE_DIR"

SIGNING_IDENTITY="${CODESIGN_IDENTITY:--}"
NOTARY_ARGS=()
NOTARY_AUTH_MODE="none"

configure_notary_auth() {
  local modes=0
  [[ "$APPLE_ID_AUTH_REQUESTED" == "0" ]] || die \
    "Apple ID password environment auth is unsupported; store it in a notarytool Keychain profile"
  [[ -n "$NOTARYTOOL_PROFILE_VALUE" ]] && modes=$((modes + 1))
  if [[ -n "$APPLE_API_KEY_PATH_VALUE$APPLE_API_KEY_ID_VALUE$APPLE_API_ISSUER_ID_VALUE" ]]; then
    modes=$((modes + 1))
  fi
  [[ "$modes" -eq 1 ]] || die \
    "set exactly one notary auth mode: NOTARYTOOL_PROFILE or API key variables"

  if [[ -n "$NOTARYTOOL_PROFILE_VALUE" ]]; then
    NOTARY_AUTH_MODE="keychain profile"
    NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE_VALUE")
    if [[ -n "$NOTARYTOOL_KEYCHAIN_PATH_VALUE" ]]; then
      NOTARY_ARGS+=(--keychain "$NOTARYTOOL_KEYCHAIN_PATH_VALUE")
    fi
  else
    [[ -n "$APPLE_API_KEY_PATH_VALUE" && -n "$APPLE_API_KEY_ID_VALUE" ]] || die \
      "API key auth requires APPLE_API_KEY_PATH and APPLE_API_KEY_ID"
    NOTARY_AUTH_MODE="App Store Connect API key"
    NOTARY_ARGS=(--key "$APPLE_API_KEY_PATH_VALUE" --key-id "$APPLE_API_KEY_ID_VALUE")
    if [[ -n "$APPLE_API_ISSUER_ID_VALUE" ]]; then
      NOTARY_ARGS+=(--issuer "$APPLE_API_ISSUER_ID_VALUE")
    fi
  fi
}

if [[ "$NOTARIZE" == "1" ]]; then
  [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]] || die \
    "formal release requires CODESIGN_IDENTITY='Developer ID Application: Name (TEAMID)'"
  [[ "$CODESIGN_IDENTITY" == Developer\ ID\ Application:* ]] || die \
    "CODESIGN_IDENTITY must be a Developer ID Application identity"
  SIGNING_IDENTITY="$CODESIGN_IDENTITY"
  configure_notary_auth
fi

NOTARY_TIMEOUT="${NOTARYTOOL_TIMEOUT:-30m}"
[[ "$NOTARY_TIMEOUT" =~ ^[0-9]+[smh]?$ ]] || die "invalid NOTARYTOOL_TIMEOUT: $NOTARY_TIMEOUT"

ARCHIVE_NAME="$APP_NAME-$VERSION-macos-universal.zip"
CHECKSUM_NAME="$ARCHIVE_NAME.sha256"

if [[ "$DRY_RUN" == "1" ]]; then
  echo "TokenBar release dry run"
  echo "  mode: $([[ "$NOTARIZE" == "1" ]] && echo 'Developer ID + notarization' || echo 'build-only; not distributable')"
  echo "  version/build: $VERSION ($BUILD_NUMBER)"
  echo "  bundle identifier: $BUNDLE_IDENTIFIER"
  echo "  architectures: arm64, x86_64"
  echo "  output: $RELEASE_DIR"
  if [[ "$NOTARIZE" == "1" ]]; then
    echo "  notary auth: $NOTARY_AUTH_MODE"
  fi
  echo "No build, signing, keychain/private-key access, network request, or file write was performed."
  exit 0
fi

if [[ "$NOTARIZE" == "1" ]]; then
  require_command security
  if ! command -v syspolicy_check >/dev/null 2>&1; then
    require_command spctl
  fi
  xcrun --find notarytool >/dev/null 2>&1 || die "notarytool is unavailable; install current Xcode tools"
  xcrun --find stapler >/dev/null 2>&1 || die "stapler is unavailable; install current Xcode tools"
  IDENTITIES="$(security find-identity -v -p codesigning)" || die "could not read signing identities"
  [[ "$IDENTITIES" == *"$SIGNING_IDENTITY"* ]] || die \
    "Developer ID identity not found in the active keychain: $SIGNING_IDENTITY"
  if [[ "$NOTARY_AUTH_MODE" == "App Store Connect API key" ]]; then
    [[ -f "$APPLE_API_KEY_PATH_VALUE" ]] || die "APPLE_API_KEY_PATH does not exist"
    KEY_PARENT="$(cd "$(dirname "$APPLE_API_KEY_PATH_VALUE")" && pwd -P)"
    KEY_ABSOLUTE="$KEY_PARENT/$(basename "$APPLE_API_KEY_PATH_VALUE")"
    [[ "$KEY_ABSOLUTE" != "$ROOT"/* ]] || die "refusing an API private key stored inside the repository"
  fi
fi

for rust_target in aarch64-apple-darwin x86_64-apple-darwin; do
  TARGET_LIBDIR="$(rustc --print target-libdir --target "$rust_target" 2>/dev/null || true)"
  [[ -n "$TARGET_LIBDIR" && -d "$TARGET_LIBDIR" ]] || die \
    "Rust target $rust_target is missing; run: rustup target add $rust_target"
done

mkdir -p "$RELEASE_DIR"
RELEASE_DIR="$(cd "$RELEASE_DIR" && pwd -P)"
[[ "$RELEASE_DIR" != "/" && "$RELEASE_DIR" != "$ROOT" && "$RELEASE_DIR" != "${HOME:-}" ]] || \
  die "unsafe canonical release directory: $RELEASE_DIR"
FINAL_APP="$RELEASE_DIR/$APP_NAME.app"
FINAL_ZIP="$RELEASE_DIR/$ARCHIVE_NAME"
FINAL_SHA="$RELEASE_DIR/$CHECKSUM_NAME"
for output in "$FINAL_APP" "$FINAL_ZIP" "$FINAL_SHA"; do
  [[ ! -e "$output" && ! -L "$output" ]] || die "output already exists; remove it explicitly: $output"
done

WORK_DIR="$(mktemp -d "$RELEASE_DIR/.tokenbar-release.XXXXXX")"
cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

THIN_DIR="$WORK_DIR/thin"
APP_PATH="$WORK_DIR/output/$APP_NAME.app"
mkdir -p "$THIN_DIR" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Helpers" "$APP_PATH/Contents/Resources"

build_swift_arch() {
  local arch="$1"
  local triple="$2"
  local scratch="$WORK_DIR/swift-$arch"
  echo "Building Swift $arch..."
  swift build --package-path "$ROOT" --scratch-path "$scratch" -c release \
    --triple "$triple" --product "$SWIFT_PRODUCT"
  local bin_dir
  bin_dir="$(swift build --package-path "$ROOT" --scratch-path "$scratch" -c release \
    --triple "$triple" --show-bin-path)"
  [[ -x "$bin_dir/$SWIFT_PRODUCT" ]] || die "missing Swift $arch executable"
  cp "$bin_dir/$SWIFT_PRODUCT" "$THIN_DIR/$SWIFT_PRODUCT-$arch"
}

build_rust_arch() {
  local arch="$1"
  local target="$2"
  echo "Building Rust $arch..."
  CARGO_ENCODED_RUSTFLAGS="$RUST_BUILD_FLAGS" cargo build \
    --manifest-path "$RUST_MANIFEST" --target-dir "$WORK_DIR/rust" \
    --locked --release --target "$target" --bin "$RUST_PRODUCT"
  local executable="$WORK_DIR/rust/$target/release/$RUST_PRODUCT"
  [[ -x "$executable" ]] || die "missing Rust $arch executable"
  cp "$executable" "$THIN_DIR/$RUST_PRODUCT-$arch"
}

build_swift_arch arm64 arm64-apple-macosx14.0
build_swift_arch x86_64 x86_64-apple-macosx14.0
build_rust_arch arm64 aarch64-apple-darwin
build_rust_arch x86_64 x86_64-apple-darwin

lipo -create "$THIN_DIR/$SWIFT_PRODUCT-arm64" "$THIN_DIR/$SWIFT_PRODUCT-x86_64" \
  -output "$APP_PATH/Contents/MacOS/$SWIFT_PRODUCT"
lipo -create "$THIN_DIR/$RUST_PRODUCT-arm64" "$THIN_DIR/$RUST_PRODUCT-x86_64" \
  -output "$APP_PATH/Contents/Helpers/$RUST_PRODUCT"

verify_universal() {
  local executable="$1"
  local architectures
  architectures="$(lipo -archs "$executable")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || die \
    "not Universal 2: $executable ($architectures)"
}
verify_universal "$APP_PATH/Contents/MacOS/$SWIFT_PRODUCT"
verify_universal "$APP_PATH/Contents/Helpers/$RUST_PRODUCT"

cp "$INFO_PLIST" "$APP_PATH/Contents/Info.plist"
cp "$ICON" "$APP_PATH/Contents/Resources/AppIcon.icns"
cp "$THIRD_PARTY_LICENSES" "$APP_PATH/Contents/Resources/ThirdPartyLicenses.html"
for notice in LICENSE THIRD_PARTY_NOTICES.md; do
  [[ ! -f "$ROOT/$notice" ]] || cp "$ROOT/$notice" "$APP_PATH/Contents/Resources/$notice"
done
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP_PATH/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" "$APP_PATH/Contents/Info.plist"
chmod 755 "$APP_PATH/Contents/MacOS/$SWIFT_PRODUCT" "$APP_PATH/Contents/Helpers/$RUST_PRODUCT"

# Resource forks and AppleDouble files can invalidate the sealed app after zip extraction.
xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete
[[ -z "$(find "$APP_PATH" -name '._*' -print -quit)" ]] || die "AppleDouble files remain in app bundle"

SIGN_ARGS=(--force --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != "-" ]]; then
  SIGN_ARGS+=(--timestamp --options runtime)
fi
codesign "${SIGN_ARGS[@]}" "$APP_PATH/Contents/Helpers/$RUST_PRODUCT"
codesign "${SIGN_ARGS[@]}" "$APP_PATH/Contents/MacOS/$SWIFT_PRODUCT"
codesign "${SIGN_ARGS[@]}" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  UPLOAD_ZIP="$WORK_DIR/notary-upload.zip"
  ditto --norsrc -c -k --keepParent "$APP_PATH" "$UPLOAD_ZIP"
  echo "Submitting to Apple notary service and waiting (timeout $NOTARY_TIMEOUT)..."
  xcrun notarytool submit "${NOTARY_ARGS[@]}" --wait --timeout "$NOTARY_TIMEOUT" "$UPLOAD_ZIP"
  xcrun stapler staple "$APP_PATH"
else
  echo "WARNING: build-only output is not notarized and is not suitable for direct distribution." >&2
  echo "WARNING: Gatekeeper may require right-click Open on another Mac." >&2
fi

xattr -cr "$APP_PATH"
find "$APP_PATH" -name '._*' -delete
[[ -z "$(find "$APP_PATH" -name '._*' -print -quit)" ]] || die "AppleDouble files remain in app bundle"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
if [[ "$NOTARIZE" == "1" ]]; then
  xcrun stapler validate "$APP_PATH"
  if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$APP_PATH"
  else
    spctl --assess --type execute --verbose=4 "$APP_PATH"
  fi
fi

STAGED_ZIP="$WORK_DIR/output/$ARCHIVE_NAME"
STAGED_SHA="$WORK_DIR/output/$CHECKSUM_NAME"
ditto --norsrc -c -k --keepParent "$APP_PATH" "$STAGED_ZIP"
(
  cd "$(dirname "$STAGED_ZIP")"
  shasum -a 256 "$ARCHIVE_NAME" > "$CHECKSUM_NAME"
)

mv "$APP_PATH" "$FINAL_APP"
mv "$STAGED_ZIP" "$FINAL_ZIP"
mv "$STAGED_SHA" "$FINAL_SHA"

echo "Created Universal 2 app: $FINAL_APP"
echo "Created archive: $FINAL_ZIP"
echo "Created checksum: $FINAL_SHA"
if [[ "$NOTARIZE" == "0" ]]; then
  echo "Build-only mode completed; this output is not notarized or directly distributable."
fi
