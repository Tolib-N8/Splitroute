#!/bin/sh
# Клипы для ролика: Splitroute в демо-режиме (SPLITROUTE_DEMO=1), запись окна через ScreenCaptureKit.
#   sh promo/record.sh   (нужен скомпилированный рекордер: swiftc -O -o promo/.bin/record promo/record.swift)
# Потом монтаж: cd promo && npm install --registry=https://registry.npmmirror.com && npm run render
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
REC="$ROOT/promo/.bin/record"
CLIPS="$ROOT/promo/public/clips"
APP=/Applications/Splitroute.app
D=com.splitroute.app
mkdir -p "$CLIPS" "$ROOT/promo/public/icons"
swift "$ROOT/promo/icons.swift" "$ROOT/promo/public/icons"
PREV_SCREEN=$(defaults read $D screen 2>/dev/null || echo routes)

quit_app() {
  osascript -e 'quit app "Splitroute"' >/dev/null 2>&1 || true
  for _ in $(seq 40); do pgrep -f "$APP/Contents/MacOS/Splitroute" >/dev/null || return 0; sleep 0.25; done
}

quit_app
defaults write $D screen routes
"$REC" main 5.6 "$CLIPS/splash.mov" &
open --env SPLITROUTE_DEMO=1 --env SPLITROUTE_SPLASH_DELAY=2 "$APP"
wait
sleep 0.5
"$REC" main 7 "$CLIPS/routes.mov"
defaults write $D screen apps; sleep 1.5
"$REC" main 3.5 "$CLIPS/apps.mov"

quit_app
defaults write $D screen servers
open --env SPLITROUTE_DEMO=1 --env SPLITROUTE_DEMO_HK_DOWN=1 "$APP"
sleep 4.5
"$REC" main 3.5 "$CLIPS/servers.mov"

quit_app
open --env SPLITROUTE_DEMO=1 --env SPLITROUTE_PANEL_PREVIEW=1 "$APP"
sleep 4
"$REC" panel 5 "$CLIPS/panel.mov"

quit_app
defaults write $D screen "$PREV_SCREEN"
open "$APP"
echo "Клипы: $CLIPS"
