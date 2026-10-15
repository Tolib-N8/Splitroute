#!/bin/sh
# Донаты: ссылки из support.json → README (оба), .github/FUNDING.yml (кнопка Sponsor на GitHub)
# и, с PUBLISH=1, блок `support` в appcast.json последнего релиза (приложения подхватят без нового релиза).
#   sh scripts/support.sh              — обновить README и FUNDING.yml локально
#   PUBLISH=1 sh scripts/support.sh    — и залить ссылки в опубликованный фид
#
# support.json — полные https-ссылки или null:
#   githubSponsors  https://github.com/sponsors/<ник>
#   kofi            https://ko-fi.com/<ник>
#   buyMeACoffee    https://buymeacoffee.com/<ник>
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
REPO=Tolib-N8/Splitroute

python3 - <<'PY'
import json, os, re
links = json.load(open("support.json"))
def handle(url):
    return url.rstrip("/").rsplit("/", 1)[-1] if url else None
items = [("GitHub Sponsors", links.get("githubSponsors")), ("Ko-fi", links.get("kofi")), ("Buy Me a Coffee", links.get("buyMeACoffee"))]
items = [(t, u) for t, u in items if u and u.startswith("https://")]

# README: блок между маркерами
texts = {
    "README.md": ("## Support", "Splitroute is free and open source. If it saves you time, you can support development:"),
    "README.ru.md": ("## Поддержать", "Splitroute бесплатный и с открытым кодом. Если он экономит вам время — можно поддержать разработку:"),
}
for path, (title, line) in texts.items():
    s = open(path, encoding="utf-8").read()
    body = f"\n{title}\n\n{line} " + " · ".join(f"[{t}]({u})" for t, u in items) + "\n" if items else "\n"
    s = re.sub(r"(<!-- support:start -->).*?(<!-- support:end -->)", lambda m: m.group(1) + body + m.group(2), s, flags=re.S)
    open(path, "w", encoding="utf-8").write(s)

# FUNDING.yml
funding = []
if links.get("githubSponsors"): funding.append(f"github: [{handle(links['githubSponsors'])}]")
if links.get("kofi"): funding.append(f"ko_fi: {handle(links['kofi'])}")
if links.get("buyMeACoffee"): funding.append(f"buy_me_a_coffee: {handle(links['buyMeACoffee'])}")
if funding:
    os.makedirs(".github", exist_ok=True)
    open(".github/FUNDING.yml", "w").write("\n".join(funding) + "\n")
elif os.path.exists(".github/FUNDING.yml"):
    os.remove(".github/FUNDING.yml")
print("Ссылки:", ", ".join(t for t, _ in items) or "нет")
PY

if [ "${PUBLISH:-0}" = 1 ]; then
  TAG=$(gh release view --repo "$REPO" --json tagName -q .tagName)
  TMP=$(mktemp -d)
  gh release download "$TAG" --repo "$REPO" --pattern appcast.json --dir "$TMP"
  python3 - "$TMP/appcast.json" <<'PY'
import json, sys
feed = json.load(open(sys.argv[1]))
feed["support"] = json.load(open("support.json"))
json.dump(feed, open(sys.argv[1], "w"), ensure_ascii=False, indent=2)
PY
  gh release upload "$TAG" "$TMP/appcast.json" --repo "$REPO" --clobber
  rm -rf "$TMP"
  echo "Фид $TAG обновлён. Не забудьте закоммитить README и .github/FUNDING.yml."
fi
