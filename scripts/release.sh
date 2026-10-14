#!/bin/sh
# Выпуск: сборка → оформленный DMG → подпись Ed25519 → appcast.json → (PUBLISH=1) GitHub Release.
#   sh scripts/release.sh            — собрать dist/ локально
#   PUBLISH=1 sh scripts/release.sh  — и опубликовать релиз v$(cat VERSION)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
VERSION=$(cat VERSION)
TAG="v$VERSION"
REPO=Tolib-N8/Splitroute
NOTES="release-notes/$VERSION.md"
[ -f "$NOTES" ] || { echo "Нет $NOTES"; exit 1; }
[ -x .build-tools/venv/bin/dmgbuild ] || { python3 -m venv .build-tools/venv && .build-tools/venv/bin/pip install -q dmgbuild==1.6.5; }

swift test 2>&1 | tail -1
sh scripts/bundle.sh

mkdir -p dist
DMG="dist/Splitroute-$VERSION.dmg"
rm -f "$DMG"
.build-tools/venv/bin/dmgbuild -s scripts/dmg-settings.py \
  -D app=build/Splitroute.app -D background=Resources/dmg-background.tiff \
  "Splitroute $VERSION" "$DMG"
hdiutil verify "$DMG" >/dev/null
codesign --force --sign - "$DMG"

SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)
SIZE=$(stat -f%z "$DMG")
SIG=$(swift scripts/update-key.swift sign "$DMG")
BUILD=$(git rev-list --count HEAD)
URL=${URL:-"https://github.com/$REPO/releases/download/$TAG/Splitroute-$VERSION.dmg"}
python3 - "$VERSION" "$BUILD" "$URL" "$SIZE" "$SHA" "$SIG" "$NOTES" > dist/appcast.json <<'PY'
import json, sys, datetime
version, build, url, size, sha, sig, notes = sys.argv[1:8]
print(json.dumps({
    "version": version, "build": int(build), "url": url, "size": int(size), "sha256": sha, "signature": sig,
    "notes": open(notes, encoding="utf-8").read().split("\n## Установка")[0].strip(),
    "minimumSystemVersion": "15.0", "date": datetime.date.today().isoformat(),
}, ensure_ascii=False, indent=2))
PY
echo "Собрано: $DMG ($(du -h "$DMG" | cut -f1)), sha256 $SHA"

if [ "${PUBLISH:-0}" = 1 ]; then
  git diff --quiet && git diff --cached --quiet || { echo "Есть незакоммиченные изменения"; exit 1; }
  git tag -a "$TAG" -m "Splitroute $VERSION" 2>/dev/null || true
  git push origin HEAD "$TAG"
  gh release create "$TAG" "$DMG" dist/appcast.json --repo "$REPO" --title "Splitroute $VERSION" --notes-file "$NOTES"
  echo "Опубликовано: https://github.com/$REPO/releases/tag/$TAG"
fi
