#!/bin/sh
# Скачивает закреплённый релиз sing-box для Apple Silicon и проверяет sha256.
set -eu
VERSION=1.14.3
SHA256=0360ce634a04c26a6b4fd957517987bb4f6c8950f63435ce3c5af2fcae5860c5
ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT="$ROOT/Resources/bin"
NAME="sing-box-$VERSION-darwin-arm64"

if [ -x "$OUT/sing-box" ] && "$OUT/sing-box" version | grep -q "version $VERSION"; then
  echo "sing-box $VERSION уже на месте"; exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$NAME.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v$VERSION/$NAME.tar.gz"
echo "$SHA256  $TMP/$NAME.tar.gz" | shasum -a 256 -c -
tar -xzf "$TMP/$NAME.tar.gz" -C "$TMP"
mkdir -p "$OUT"
install -m 755 "$TMP/$NAME/sing-box" "$OUT/sing-box"
"$OUT/sing-box" version | head -1
