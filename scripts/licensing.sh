#!/bin/sh
# Продажи: обновить блок `licensing` в appcast.json последнего релиза — без нового релиза.
# Приложения перечитывают его раз в 6 часов и при запуске.
#   sh scripts/licensing.sh            — показать, что сейчас в опубликованном фиде
#   PUBLISH=1 sh scripts/licensing.sh  — залить licensing.json в фид последнего релиза
#
# licensing.json:
#   sales      — продаются ли лицензии. false: Splitroute бесплатен; все, кто запустил его при false,
#                навсегда «ранние пользователи». true: новым пользователям — пробный период trialDays дней.
#   storeID, productID — из Lemon Squeezy (Store → Settings, Product → ID); ключ чужого товара не примется.
#   buyURL     — ссылка на покупку (Product → Share), price — текст для кнопки.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
REPO=Tolib-N8/Splitroute
TAG=$(gh release view --repo "$REPO" --json tagName -q .tagName)
TMP=$(mktemp -d)
gh release download "$TAG" --repo "$REPO" --pattern appcast.json --dir "$TMP"
echo "Сейчас в $TAG:"
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])).get("licensing"), indent=2, ensure_ascii=False))' "$TMP/appcast.json"

if [ "${PUBLISH:-0}" = 1 ]; then
  python3 - "$TMP/appcast.json" <<'PY'
import json, sys
path = sys.argv[1]
feed = json.load(open(path))
lic = json.load(open("licensing.json"))
if lic.get("sales"):
    missing = [k for k in ("storeID", "productID", "buyURL") if not lic.get(k)]
    if missing:
        sys.exit("Для продаж заполните в licensing.json: " + ", ".join(missing))
feed["licensing"] = lic
json.dump(feed, open(path, "w"), ensure_ascii=False, indent=2)
PY
  gh release upload "$TAG" "$TMP/appcast.json" --repo "$REPO" --clobber
  echo "Обновлено в $TAG:"
  cat licensing.json
fi
rm -rf "$TMP"
