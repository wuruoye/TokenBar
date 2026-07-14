#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="$ROOT/Resources/ThirdPartyLicenses.html"

if ! command -v cargo-about >/dev/null 2>&1; then
  echo "cargo-about is required: cargo install cargo-about --locked --features cli" >&2
  exit 1
fi

cargo about generate \
  --manifest-path "$ROOT/Helper/Cargo.toml" \
  --config "$ROOT/Helper/about.toml" \
  --locked \
  --fail \
  --output-file "$OUTPUT" \
  "$ROOT/Helper/about.hbs"

echo "Created $OUTPUT"
