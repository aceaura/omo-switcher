#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLIENT="$ROOT/client"
OUT="$ROOT/release/installer"
APP="$CLIENT/build/macos/Build/Products/Release/omo_switcher_client.app"
PKG="$OUT/omo-switcher-macos.pkg"

# Derive the package version from client/pubspec.yaml (e.g. "1.0.6+7" -> "1.0.6").
VERSION_LINE="$(grep -E '^[[:space:]]*version:[[:space:]]*' "$CLIENT/pubspec.yaml" | head -1)"
PKG_VERSION="$(printf '%s' "${VERSION_LINE#*version:}" | tr -d '[:space:]')"
PKG_VERSION="${PKG_VERSION%%+*}"
PKG_VERSION="${PKG_VERSION:-1.0.0}"

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
  --version "$PKG_VERSION" \
  "$PKG"

echo "Built $PKG"
