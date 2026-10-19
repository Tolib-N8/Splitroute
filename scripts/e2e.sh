#!/bin/sh
# Сквозная проверка на живой системе (компонент должен быть установлен из Splitroute.app).
#   - две копии curl: одна → VPN-приложение, другая → напрямую; IP на выходе должны различаться;
#   - Tailscale (100.100.100.100) продолжает отвечать;
#   - kill switch: если VPN-сервис «пропал», VPN-копия получает отказ, а не прямой IP;
#   - вход проверки выходов (probe-in): без пароля — отказ, с тегом выхода — через этот выход;
#   - выход из health.json («не отвечает») уходит в резерв.
# Текущий профиль и health.json сохраняются и восстанавливаются в конце.
set -u
VPN_NAME=${1:-ZoogVPN}
HELPER=/Library/PrivilegedHelperTools/com.splitroute/splitroute-helper
PROFILE="$HOME/Library/Application Support/Splitroute/profile.json"
HEALTH="$HOME/Library/Application Support/Splitroute/health.json"
HEALTH_BACKUP=$(mktemp)
cp "$HEALTH" "$HEALTH_BACKUP" 2>/dev/null || echo '{"unhealthy":[]}' > "$HEALTH_BACKUP"
BACKUP=$(mktemp)
# IP на выходе: Cloudflare trace, а если он недоступен — myip.ipip.net. ip-api не годится: некоторые VPN
# (AIRLINK) сами пускают его напрямую, и VPN-копия показывала бы прямой IP.
myip() {
  "$1" -s -m 8 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p' | grep -Eo '([0-9]+\.){3}[0-9]+' ||
  "$1" -s -m 8 https://myip.ipip.net | grep -Eo '([0-9]+\.){3}[0-9]+' | head -1
}
fail=0

[ -x "$HELPER" ] || { echo "Компонент не установлен"; exit 1; }
cp "$PROFILE" "$BACKUP" 2>/dev/null || echo '{}' > "$BACKUP"
# Запущенный Splitroute держит свой профиль в памяти и при любой пересборке записал бы его поверх тестового —
# на время проверки закрываем приложение и открываем обратно в конце.
APP_WAS_RUNNING=0
if pgrep -f "/Applications/Splitroute.app/Contents/MacOS/Splitroute" >/dev/null; then
  APP_WAS_RUNNING=1
  osascript -e 'quit app "Splitroute"' >/dev/null 2>&1
  for _ in $(seq 40); do pgrep -f "/Applications/Splitroute.app/Contents/MacOS/Splitroute" >/dev/null || break; sleep 0.25; done
fi
restore() {
  cp "$BACKUP" "$PROFILE"; cp "$HEALTH_BACKUP" "$HEALTH"; sudo -n "$HELPER" apply >/dev/null; rm -f "$BACKUP" "$HEALTH_BACKUP"
  [ "$APP_WAS_RUNNING" = 1 ] && open /Applications/Splitroute.app
}
trap restore EXIT

for d in sr-vpn sr-direct; do
  mkdir -p /tmp/$d && cp /usr/bin/curl /tmp/$d/curl && codesign -f -s - /tmp/$d/curl 2>/dev/null
done

SERVICE=$("$HELPER" env | awk -v n="$VPN_NAME" '$1=="vpn:" && index($0, n) {for(i=2;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')
[ -n "$SERVICE" ] || { echo "VPN-сервис $VPN_NAME не найден"; exit 1; }

write_profile() { # $1 = serviceID для выхода VPN, $2 = его fallbackID (пусто — любой доступный), $3 = serviceID резервного выхода
  FB=${2:+,\"fallbackID\":\"$2\"}
  SPARE=${3:+,\{\"id\":\"e2e-spare\",\"name\":\"spare\",\"kind\":\{\"vpnApp\":\{\"serviceID\":\"$3\"\}\}\}}
  cat > "$PROFILE" <<JSON
{"version":1,"defaultExitID":"direct","killSwitch":true,"tunnelDNS":"1.1.1.1",
 "exits":[{"id":"e2e-vpn","name":"$VPN_NAME","kind":{"vpnApp":{"serviceID":"$1"}}$FB}$SPARE],
 "routes":[
  {"bundleID":"e2e.vpn","name":"curl-vpn","path":"/private/tmp/sr-vpn/","exitID":"e2e-vpn"},
  {"bundleID":"e2e.direct","name":"curl-direct","path":"/private/tmp/sr-direct/","exitID":"direct"}]}
JSON
}

check() { # имя, условие
  if eval "$2"; then echo "  ✔ $1"; else echo "  ✘ $1"; fail=1; fi
}

echo "1. Разделение"
write_profile "$SERVICE"
sudo -n "$HELPER" apply || exit 1
sleep 3
VPN_IP=$(myip /tmp/sr-vpn/curl)
DIRECT_IP=$(myip /tmp/sr-direct/curl)
echo "  VPN-копия:    $VPN_IP"
echo "  Прямая копия: $DIRECT_IP"
check "оба запроса прошли" '[ -n "$VPN_IP" ] && [ -n "$DIRECT_IP" ]'
check "IP различаются" '[ "$VPN_IP" != "$DIRECT_IP" ]'
G=$(/tmp/sr-vpn/curl -s -m 10 -o /dev/null -w '%{http_code}' https://www.google.com)
check "Google через VPN открывается — системный DNS без подмены ($G)" '[ "$G" = "200" ] || [ "$G" = "301" ] || [ "$G" = "302" ]'
TS=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://100.100.100.100/ 2>/dev/null)
check "Tailscale отвечает ($TS)" '[ "$TS" != "000" ]'

# Базы для раздела 3 — через VPN-копию: напрямую из Китая GitHub часто недоступен.
RS="$HOME/Library/Application Support/Splitroute/rulesets"
mkdir -p "$RS"
for tag in geosite-cn geoip-cn; do
  repo=sing-geosite; [ "${tag#geoip}" != "$tag" ] && repo=sing-geoip
  [ -s "$RS/$tag.srs" ] || /tmp/sr-vpn/curl -fsSL -m 30 -o "$RS/$tag.srs" "https://raw.githubusercontent.com/SagerNet/$repo/rule-set/$tag.srs"
done

echo "2. Kill switch (VPN-сервис недоступен, резерв выключен)"
write_profile "00000000-0000-0000-0000-000000000000" none "$SERVICE"
sudo -n "$HELPER" apply || exit 1
sleep 3
KS=$(myip /tmp/sr-vpn/curl)
echo "  VPN-копия: ${KS:-отказ}"
check "VPN-копия заблокирована" '[ -z "$KS" ]'

echo "2b. Резерв (VPN-сервис недоступен → любой подключённый VPN)"
write_profile "00000000-0000-0000-0000-000000000000" "" "$SERVICE"
sudo -n "$HELPER" apply || exit 1
sleep 3
FB_IP=$(myip /tmp/sr-vpn/curl)
echo "  VPN-копия: ${FB_IP:-отказ}"
check "VPN-копия ушла в резервный VPN" '[ -n "$FB_IP" ] && [ "$FB_IP" = "$VPN_IP" ]'

echo "3. Правила и наборы (свои правила → наборы → маршрут приложения)"
cat > "$PROFILE" <<JSON
{"version":1,"defaultExitID":"direct","killSwitch":true,"tunnelDNS":"1.1.1.1",
 "exits":[{"id":"e2e-vpn","name":"$VPN_NAME","kind":{"vpnApp":{"serviceID":"$SERVICE"}}}],
 "routes":[
  {"bundleID":"e2e.vpn","name":"curl-vpn","path":"/private/tmp/sr-vpn/","exitID":"e2e-vpn"},
  {"bundleID":"e2e.direct","name":"curl-direct","path":"/private/tmp/sr-direct/","exitID":"direct"}],
 "rules":[{"id":"r1","enabled":true,"kind":"domain","values":["one.one.one.one"],"appPaths":[],"exitID":"e2e-vpn"}],
 "presets":[{"id":"cn","enabled":true,"exitID":"direct"}]}
JSON
sudo -n "$HELPER" apply || exit 1
sleep 3
trace() { "$1" -s -m 8 https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p'; }
RULE_IP=$(/tmp/sr-direct/curl -s -m 8 https://one.one.one.one/cdn-cgi/trace | sed -n 's/^ip=//p')
APP_DIRECT=$(trace /tmp/sr-direct/curl)
APP_VPN=$(trace /tmp/sr-vpn/curl)
PRESET_IP=$(/tmp/sr-vpn/curl -s -m 8 https://myip.ipip.net | grep -Eo '([0-9]+\.){3}[0-9]+' | head -1)
echo "  прямая копия → one.one.one.one (правило → VPN): $RULE_IP"
echo "  прямая копия → cloudflare (маршрут приложения): $APP_DIRECT"
echo "  VPN-копия → cloudflare (маршрут приложения):    $APP_VPN"
echo "  VPN-копия → myip.ipip.net (набор «Китай»):      $PRESET_IP"
check "правило по домену перебивает маршрут приложения" '[ -n "$RULE_IP" ] && [ "$RULE_IP" = "$VPN_IP" ]'
check "без правил работает маршрут приложения (напрямую)" '[ -n "$APP_DIRECT" ] && [ "$APP_DIRECT" = "$DIRECT_IP" ]'
check "без правил работает маршрут приложения (VPN)" '[ -n "$APP_VPN" ] && [ "$APP_VPN" = "$VPN_IP" ]'
check "набор «Китайские сервисы» перебивает маршрут приложения" '[ -n "$PRESET_IP" ] && [ "$PRESET_IP" = "$DIRECT_IP" ]'

echo "4. Вход проверки выходов (probe-in)"
write_profile "$SERVICE"
sudo -n "$HELPER" apply || exit 1
sleep 3
SECRET=$(python3 -c 'import json;print(json.load(open("/Library/Application Support/Splitroute/api.json"))["secret"])')
PROBE=$(python3 -c 'import json;print(json.load(open("/Library/Application Support/Splitroute/api.json")).get("probe") or "")')
P_NOAUTH=$(curl -s -m 8 --socks5-hostname "$PROBE" https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p')
P_VPN=$(curl -s -m 8 --socks5-hostname "$PROBE" --proxy-user "exit-e2e-vpn:$SECRET" https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p')
P_DIRECT=$(curl -s -m 8 --socks5-hostname "$PROBE" --proxy-user "direct:$SECRET" https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p')
P_AUTO=$(curl -s -m 8 --socks5-hostname "$PROBE" --proxy-user "auto:$SECRET" https://www.cloudflare.com/cdn-cgi/trace | sed -n 's/^ip=//p')
echo "  без пароля: ${P_NOAUTH:-отказ} · VPN: $P_VPN · напрямую: $P_DIRECT · авто: $P_AUTO"
check "без пароля — отказ" '[ -z "$P_NOAUTH" ]'
check "проба через VPN-выход даёт IP VPN" '[ -n "$P_VPN" ] && [ "$P_VPN" = "$VPN_IP" ]'
check "проба напрямую даёт прямой IP" '[ -n "$P_DIRECT" ] && [ "$P_DIRECT" = "$DIRECT_IP" ]'
check "«Авто» выбрал работающий VPN" '[ -n "$P_AUTO" ] && [ "$P_AUTO" = "$VPN_IP" ]'

echo "5. Выход «не отвечает» (health.json) → резерв"
cat > "$PROFILE" <<JSON
{"version":1,"defaultExitID":"direct","killSwitch":true,"tunnelDNS":"1.1.1.1",
 "exits":[{"id":"e2e-dead","name":"dead","kind":{"vpnApp":{"serviceID":"$SERVICE"}}},
          {"id":"e2e-spare","name":"spare","kind":{"vpnApp":{"serviceID":"$SERVICE"}}}],
 "routes":[{"bundleID":"e2e.vpn","name":"curl-vpn","path":"/private/tmp/sr-vpn/","exitID":"e2e-dead"}]}
JSON
echo '{"unhealthy":["e2e-dead"]}' > "$HEALTH"
sudo -n "$HELPER" apply || exit 1
sleep 3
H_IP=$(myip /tmp/sr-vpn/curl)
RULE=$("$HELPER" preview 2>/dev/null | python3 -c 'import json,sys;c=json.load(sys.stdin);print([r.get("outbound") for r in c["route"]["rules"] if "/private/tmp/sr-vpn/" in str(r.get("process_path_regex","")) and "ip_version" not in r][0])' 2>/dev/null)
echo "  VPN-копия → ${RULE:-?}, IP ${H_IP:-отказ}"
check "неотвечающий выход ушёл в резерв" '[ "$RULE" = "exit-e2e-spare" ] && [ "$H_IP" = "$VPN_IP" ]'

exit $fail
