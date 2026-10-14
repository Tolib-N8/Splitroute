#!/bin/sh
# Сквозная проверка на живой системе (компонент должен быть установлен из Splitroute.app).
#   - две копии curl: одна → VPN-приложение, другая → напрямую; IP на выходе должны различаться;
#   - Tailscale (100.100.100.100) продолжает отвечать;
#   - kill switch: если VPN-сервис «пропал», VPN-копия получает отказ, а не прямой IP.
# Текущий профиль сохраняется и восстанавливается в конце.
set -u
VPN_NAME=${1:-ZoogVPN}
HELPER=/Library/PrivilegedHelperTools/com.splitroute/splitroute-helper
PROFILE="$HOME/Library/Application Support/Splitroute/profile.json"
BACKUP=$(mktemp)
# IP на выходе: ip-api, а если он недоступен (бывает из Китая напрямую) — myip.ipip.net.
myip() {
  "$1" -s -m 8 'http://ip-api.com/line/?fields=query' | head -1 | grep -Eo '([0-9]+\.){3}[0-9]+' ||
  "$1" -s -m 8 https://myip.ipip.net | grep -Eo '([0-9]+\.){3}[0-9]+' | head -1
}
fail=0

[ -x "$HELPER" ] || { echo "Компонент не установлен"; exit 1; }
cp "$PROFILE" "$BACKUP" 2>/dev/null || echo '{}' > "$BACKUP"
restore() { cp "$BACKUP" "$PROFILE"; sudo -n "$HELPER" apply >/dev/null; rm -f "$BACKUP"; }
trap restore EXIT

for d in sr-vpn sr-direct; do
  mkdir -p /tmp/$d && cp /usr/bin/curl /tmp/$d/curl && codesign -f -s - /tmp/$d/curl 2>/dev/null
done

SERVICE=$("$HELPER" env | awk -v n="$VPN_NAME" '$1=="vpn:" && index($0, n) {for(i=2;i<=NF;i++) if ($i ~ /^[0-9A-F-]{36}$/) {print $i; exit}}')
[ -n "$SERVICE" ] || { echo "VPN-сервис $VPN_NAME не найден"; exit 1; }

write_profile() { # $1 = serviceID для выхода VPN
  cat > "$PROFILE" <<JSON
{"version":1,"defaultExitID":"direct","killSwitch":true,"tunnelDNS":"1.1.1.1",
 "exits":[{"id":"e2e-vpn","name":"$VPN_NAME","kind":{"vpnApp":{"serviceID":"$1"}}}],
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
TS=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://100.100.100.100/ 2>/dev/null)
check "Tailscale отвечает ($TS)" '[ "$TS" != "000" ]'

echo "2. Kill switch (VPN-сервис недоступен)"
write_profile "00000000-0000-0000-0000-000000000000"
sudo -n "$HELPER" apply || exit 1
sleep 3
KS=$(myip /tmp/sr-vpn/curl)
echo "  VPN-копия: ${KS:-отказ}"
check "VPN-копия заблокирована" '[ -z "$KS" ]'

exit $fail
