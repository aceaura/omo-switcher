#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$ROOT/client"
OUT="$ROOT/release/installer"
APP="$CLIENT/build/macos/Build/Products/Release/omo_switcher_client.app"
PKG="$OUT/omo-switcher-macos.pkg"

SKIP_BUILD="${SKIP_BUILD:-0}"

if [[ "$SKIP_BUILD" != "1" ]]; then
  (cd "$CLIENT" && flutter build macos --release)
fi

if [[ ! -d "$APP" ]]; then
  echo "macOS release app was not found: $APP" >&2
  exit 1
fi

mkdir -p "$OUT"
pkgbuild \
  --component "$APP" \
  --install-location "/Applications" \
  --identifier "com.aceaura.omo-switcher" \
  --version "1.0.0" \
  "$PKG"

echo "Built $PKG"
